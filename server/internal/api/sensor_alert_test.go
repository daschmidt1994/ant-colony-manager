package api_test

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestSensorLimitCreatesProblemOnceWithinPause(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	colony := anna.CreateColony(t, map[string]any{"name": "Messor #12"})
	res := anna.Do("POST", "/api/v1/sensors", map[string]any{"name": "Regal A", "colony_id": colony,
		"temp_min": 18, "temp_max": 28}).Must(t, http.StatusCreated).JSON()
	id := res["data"].(map[string]any)["id"].(string)
	key := res["extra"].(map[string]any)["api_key"].(string)

	send := func(metric string, v float64, at time.Time) {
		t.Helper()
		env.Anon().Do("POST", "/api/v1/sensors/"+id+"/measurements", map[string]any{
			"readings": []map[string]any{{"metric": metric, "value": v, "measured_at": at}},
		}, "Authorization", "Bearer "+key).Must(t, http.StatusAccepted)
	}
	problems := func() int {
		return env.Count(t, `SELECT count(*) FROM colony_events WHERE colony_id = $1 AND type = 'problem'`, colony)
	}

	send("temperature", 24, time.Now())
	if problems() != 0 {
		t.Fatal("alert within limits")
	}
	send("temperature", 31.5, time.Now())
	if problems() != 1 {
		t.Fatalf("expected 1 problem, got %d", problems())
	}
	var note string
	if err := env.Pool.QueryRow(t.Context(), `SELECT note FROM colony_events WHERE colony_id = $1 AND type = 'problem'`, colony).Scan(&note); err != nil {
		t.Fatal(err)
	}
	if note != "Sensor „Regal A“: Temperatur 31,5 °C – über dem Grenzwert 28,0 °C." {
		t.Fatalf("note: %s", note)
	}
	send("temperature", 32, time.Now().Add(time.Minute))
	if problems() != 1 {
		t.Fatal("alerted again within the pause")
	}
	send("humidity", 99, time.Now())                      // no humidity limits set
	send("temperature", 40, time.Now().Add(-5*time.Hour)) // back-filled, old
	if problems() != 1 {
		t.Fatal("unexpected alert")
	}
	// The problem reaches the devices like any other entry.
	found := false
	for _, c := range anna.Pull(t, 0).Changes {
		if c.Entity == "colony_events" && strings.Contains(strings.ReplaceAll(string(c.Data), " ", ""), `"source":"sensor"`) {
			found = true
		}
	}
	if !found {
		t.Fatal("sensor problem not in pull")
	}
}
