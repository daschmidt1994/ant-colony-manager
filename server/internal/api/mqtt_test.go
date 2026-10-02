package api_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// fakeBroker keeps the retained messages like a broker does: an empty
// message deletes the retained one.
type fakeBroker struct {
	mu        sync.Mutex
	retained  map[string]string
	published int
	opts      []service.MQTTOptions
	closed    int
	fail      error
}

func (b *fakeBroker) dial(_ context.Context, o service.MQTTOptions) (service.MQTTConn, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.fail != nil {
		return nil, b.fail
	}
	b.opts = append(b.opts, o)
	return &fakeConn{b: b}, nil
}

type fakeConn struct {
	b      *fakeBroker
	closed bool
}

func (c *fakeConn) Publish(topic string, payload []byte) error {
	c.b.mu.Lock()
	defer c.b.mu.Unlock()
	c.b.published++
	if len(payload) == 0 {
		delete(c.b.retained, topic)
	} else {
		c.b.retained[topic] = string(payload)
	}
	return nil
}
func (c *fakeConn) Connected() bool { return !c.closed }
func (c *fakeConn) Close()          { c.closed = true; c.b.mu.Lock(); c.b.closed++; c.b.mu.Unlock() }

func (b *fakeBroker) get(t *testing.T, topic string) map[string]any {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	raw, ok := b.retained[topic]
	if !ok {
		t.Fatalf("nothing retained on %s", topic)
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatalf("%s: %v", topic, err)
	}
	return v
}

func (b *fakeBroker) has(topic string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	_, ok := b.retained[topic]
	return ok
}

func (b *fakeBroker) count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.published
}

func TestMQTTHomeAssistantDiscovery(t *testing.T) {
	env := testenv.New(t)
	admin := env.Admin(t)
	ben := env.User(t, "Ben")
	ctx := context.Background()
	broker := &fakeBroker{retained: map[string]string{}}
	env.Svc.MQTTDial = broker.dial

	ben.Do("GET", "/api/v1/admin/mqtt", nil).Must(t, 403)
	s := admin.Do("GET", "/api/v1/admin/mqtt", nil).Must(t, 200).JSON()
	if s["enabled"] != false || s["prefix"] != "homeassistant" {
		t.Fatalf("defaults: %v", s)
	}
	for _, bad := range []map[string]any{
		{"enabled": true, "url": ""},
		{"enabled": true, "url": "http://192.168.178.199:1883"},
		{"enabled": true, "url": "192.168.178.199:99999"},
		{"enabled": true, "url": "192.168.178.199", "prefix": "home/#"},
	} {
		admin.Do("PUT", "/api/v1/admin/mqtt", bad).Must(t, 422)
	}

	messor := admin.CreateColony(t, map[string]any{"name": "Messor", "species_text": "Messor barbarus"})
	lasius := admin.CreateColony(t, map[string]any{"name": "Lasius", "species_text": ""})
	ben.CreateColony(t, map[string]any{"name": "Bens Kolonie"}) // not the admin's: never sent
	admin.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": messor, "task_type": "protein", "interval_days": 2,
			"starts_at": time.Now().Add(-5 * 24 * time.Hour)})})

	s = admin.Do("PUT", "/api/v1/admin/mqtt", map[string]any{"enabled": true, "url": "192.168.178.199",
		"user": "acm", "password": "geheim"}).Must(t, 200).JSON()
	if s["url"] != "mqtt://192.168.178.199:1883" || s["password_set"] != true || s["password"] != nil || s["owner"] != "Admin" {
		t.Fatalf("saved: %v", s)
	}
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	if o := broker.opts[0]; o.URL != "mqtt://192.168.178.199:1883" || o.User != "acm" || o.Password != "geheim" ||
		o.WillTopic != "ant-colony-manager/status" || o.HAStatusTopic != "homeassistant/status" {
		t.Fatalf("dial options: %+v", o)
	}

	number := func(id uuid.UUID) string {
		n := admin.Do("GET", "/api/v1/colonies/"+id.String(), nil).Must(t, 200).JSON()["colony"].(map[string]any)["number"].(float64)
		return strconv.Itoa(int(n))
	}
	cfg := broker.get(t, "homeassistant/device/acm_"+messor.String()+"/config")
	cmps := cfg["components"].(map[string]any)
	overdue := cmps["overdue"].(map[string]any)
	if overdue["platform"] != "sensor" || overdue["unique_id"] != "acm_"+messor.String()+"_overdue" ||
		overdue["default_entity_id"] != "sensor.acm_colony_"+number(messor)+"_overdue" ||
		cfg["state_topic"] != "ant-colony-manager/colony/"+messor.String()+"/state" ||
		cfg["device"].(map[string]any)["name"] != "Messor (#"+number(messor)+")" {
		t.Fatalf("config: %v", cfg)
	}
	if cmps["hibernation"].(map[string]any)["platform"] != "binary_sensor" || cmps["temperature"] != nil {
		t.Fatalf("components: %v", cmps)
	}
	st := broker.get(t, "ant-colony-manager/colony/"+messor.String()+"/state")
	if st["overdue"] != float64(1) || st["hibernating"] != false || st["next_task"] != "Proteinfütterung" {
		t.Fatalf("state: %v", st)
	}
	if st := broker.get(t, "ant-colony-manager/colony/"+lasius.String()+"/state"); st["next_due_at"] != nil ||
		st["next_due"] == nil {
		t.Fatalf("lasius state: %v", st)
	}
	if sum := broker.get(t, "ant-colony-manager/state"); sum["colonies"] != float64(2) || sum["overdue"] != float64(1) {
		t.Fatalf("summary: %v", sum)
	}
	if !broker.has("homeassistant/device/acm_summary/config") || len(broker.retained) != 6 {
		t.Fatalf("retained: %v", broker.retained)
	}

	// Nothing changed: nothing is sent again.
	n := broker.count()
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	if broker.count() != n {
		t.Fatalf("sent %d messages without a change", broker.count()-n)
	}

	// A new colony appears by itself …
	camponotus := admin.CreateColony(t, map[string]any{"name": "Camponotus"})
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	if !broker.has("homeassistant/device/acm_" + camponotus.String() + "/config") {
		t.Fatal("new colony not announced")
	}
	// … an archived one disappears.
	admin.Do("POST", "/api/v1/colonies/"+lasius.String()+"/archive", nil).Must(t, 200)
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	if broker.has("homeassistant/device/acm_"+lasius.String()+"/config") ||
		broker.has("ant-colony-manager/colony/"+lasius.String()+"/state") {
		t.Fatal("archived colony still in Home Assistant")
	}
	if s := admin.Do("GET", "/api/v1/admin/mqtt", nil).Must(t, 200).JSON(); s["status"].(map[string]any)["connected"] != true ||
		s["status"].(map[string]any)["colonies"] != float64(2) {
		t.Fatalf("status: %v", s["status"])
	}

	// Test button: a separate connection without last will.
	admin.Do("POST", "/api/v1/admin/mqtt/test", nil).Must(t, 204)
	if o := broker.opts[len(broker.opts)-1]; o.WillTopic != "" || !strings.HasSuffix(o.ClientID, "-test") {
		t.Fatalf("test options: %+v", o)
	}
	broker.fail = errors.New("connection refused")
	if r := admin.Do("POST", "/api/v1/admin/mqtt/test", nil).Must(t, 502); !strings.Contains(r.JSON()["title"].(string), "refused") {
		t.Fatalf("test error: %v", r.JSON())
	}
	broker.fail = nil

	// Switching off removes everything from Home Assistant (the password stays).
	s = admin.Do("PUT", "/api/v1/admin/mqtt", map[string]any{"enabled": false, "url": "192.168.178.199"}).Must(t, 200).JSON()
	if s["password_set"] != true {
		t.Fatalf("password lost: %v", s)
	}
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	for topic, v := range broker.retained {
		if topic != "ant-colony-manager/status" {
			t.Errorf("still retained after switching off: %s = %s", topic, v)
		}
	}
}

// Buttons and switches in Home Assistant act in ACM; other users can send
// their colonies too; sensor values are read from Home Assistant.
func TestHomeAssistantActionsAndSensors(t *testing.T) {
	env := testenv.New(t)
	admin := env.Admin(t)
	ben := env.User(t, "Ben")
	ctx := context.Background()
	broker := &fakeBroker{retained: map[string]string{}}
	env.Svc.MQTTDial = broker.dial

	messor := admin.CreateColony(t, map[string]any{"name": "Messor"})
	water := testenv.NewID()
	custom := testenv.NewID()
	admin.Push(t,
		testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: water, Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": messor, "task_type": "water", "interval_days": 3,
				"starts_at": time.Now().Add(-5 * 24 * time.Hour)})},
		testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: custom, Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": messor, "task_type": "custom", "title": "Nest befeuchten",
				"interval_days": 7, "starts_at": time.Now().Add(-10 * 24 * time.Hour)})},
	)
	bens := ben.CreateColony(t, map[string]any{"name": "Lasius"})

	// Ben's colonies only when Ben switches it on
	if me := ben.Do("GET", "/api/v1/me/home-assistant", nil).Must(t, 200).JSON(); me["enabled"] != false || me["available"] != false {
		t.Fatalf("ben before: %v", me)
	}
	admin.Do("PUT", "/api/v1/admin/mqtt", map[string]any{"enabled": true, "url": "broker"}).Must(t, 200)
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	if broker.has("homeassistant/device/acm_" + bens.String() + "/config") {
		t.Fatal("ben's colony sent without his consent")
	}
	if me := ben.Do("PUT", "/api/v1/me/home-assistant", map[string]any{"enabled": true}).Must(t, 200).JSON(); me["enabled"] != true {
		t.Fatalf("ben: %v", me)
	}
	if err := env.Svc.MQTTSync(ctx); err != nil {
		t.Fatal(err)
	}
	cfg := broker.get(t, "homeassistant/device/acm_"+bens.String()+"/config")
	if id := cfg["components"].(map[string]any)["overdue"].(map[string]any)["default_entity_id"]; id != "sensor.acm_ben_colony_1_overdue" {
		t.Fatalf("entity id of ben's colony: %v", id)
	}
	if s := admin.Do("GET", "/api/v1/admin/mqtt", nil).Must(t, 200).JSON(); fmt.Sprint(s["members"]) != "[Ben]" {
		t.Fatalf("members: %v", s["members"])
	}

	// buttons and switch in the discovery
	cmps := broker.get(t, "homeassistant/device/acm_"+messor.String()+"/config")["components"].(map[string]any)
	btn := cmps["done_water"].(map[string]any)
	if btn["platform"] != "button" || btn["payload_press"] != water.String() || btn["name"] != "Wasser erledigt" {
		t.Fatalf("water button: %v", btn)
	}
	var customKey string
	for k := range cmps {
		if strings.HasPrefix(k, "done_custom_") {
			customKey = k
		}
	}
	if customKey == "" || cmps[customKey].(map[string]any)["name"] != "Nest befeuchten erledigt" {
		t.Fatalf("custom button missing: %v", cmps)
	}
	sw := cmps["hibernation_switch"].(map[string]any)
	if sw["platform"] != "switch" || sw["command_topic"] != "ant-colony-manager/colony/"+messor.String()+"/hibernation/set" {
		t.Fatalf("switch: %v", sw)
	}

	// pressing: the handlers come from the subscriptions of the connection
	press := func(topic, payload string) {
		t.Helper()
		for filter, handle := range broker.opts[0].Subscribe {
			if strings.HasSuffix(filter, topic[strings.LastIndex(topic, "/"):]) ||
				(strings.HasSuffix(topic, "/set") && strings.HasSuffix(filter, "/set")) {
				handle(topic, []byte(payload))
				return
			}
		}
		t.Fatalf("no subscription for %s", topic)
	}
	wait := func(what, sql string, want int, args ...any) {
		t.Helper()
		for i := 0; i < 100; i++ {
			if env.Count(t, sql, args...) == want {
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatalf("%s: want %d", what, want)
	}
	press("ant-colony-manager/colony/"+messor.String()+"/done", water.String())
	wait("water event", `SELECT count(*) FROM colony_events e JOIN waterings w ON w.event_id = e.id
		WHERE e.colony_id = $1 AND w.kinds = '{drinker_refilled}'`, 1, messor)
	press("ant-colony-manager/colony/"+messor.String()+"/done", custom.String())
	wait("custom event", `SELECT count(*) FROM colony_events WHERE colony_id = $1 AND type = 'custom_task' AND schedule_id = $2
		AND payload->>'title' = 'Nest befeuchten'`, 1, messor, custom)
	// a care plan of another colony is refused
	press("ant-colony-manager/colony/"+bens.String()+"/done", water.String())
	press("ant-colony-manager/colony/"+messor.String()+"/hibernation/set", "ON")
	wait("winter started", `SELECT count(*) FROM winter_rests WHERE colony_id = $1 AND started_on = current_date AND ended_on IS NULL`, 1, messor)
	press("ant-colony-manager/colony/"+messor.String()+"/hibernation/set", "OFF")
	wait("winter ended", `SELECT count(*) FROM winter_rests WHERE colony_id = $1 AND ended_on = current_date`, 1, messor)
	time.Sleep(200 * time.Millisecond)
	if n := env.Count(t, `SELECT count(*) FROM colony_events WHERE colony_id = $1`, bens); n != 0 {
		t.Fatalf("foreign care plan was applied to ben's colony: %d events", n)
	}

	// Home Assistant sensors: read via the REST API with the admin's token
	// one reading: the same timestamp on every request, like the real Home Assistant
	measured := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	ha := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer ha-token" {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/api/":
			w.Write([]byte(`{"message":"API running."}`))
		case "/api/states/sensor.formicarium_temperatur":
			w.Write([]byte(`{"state":"24.6","last_updated":"` + measured + `"}`))
		case "/api/states/sensor.formicarium_feuchte":
			w.Write([]byte(`{"state":"unavailable"}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer ha.Close()
	admin.Do("PUT", "/api/v1/admin/mqtt", map[string]any{"enabled": true, "url": "broker", "ha_url": "ftp://x"}).Must(t, 422)
	s := admin.Do("PUT", "/api/v1/admin/mqtt", map[string]any{"enabled": true, "url": "broker", "ha_url": ha.URL, "ha_token": "falsch"}).Must(t, 200).JSON()
	if s["ha_token_set"] != true || s["ha_token"] != nil {
		t.Fatalf("ha settings: %v", s)
	}
	admin.Do("POST", "/api/v1/admin/home-assistant/test", nil).Must(t, 502)
	admin.Do("PUT", "/api/v1/admin/mqtt", map[string]any{"enabled": true, "url": "broker", "ha_url": ha.URL, "ha_token": "ha-token"}).Must(t, 200)
	admin.Do("POST", "/api/v1/admin/home-assistant/test", nil).Must(t, 204)

	sensor := testenv.NewID()
	r := admin.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "sensors", EntityID: sensor, Op: "create",
		Payload: testenv.Payload(map[string]any{"name": "Formicarium", "kind": "home_assistant", "colony_id": messor,
			"ha_temperature_entity": "sensor.formicarium_temperatur", "ha_humidity_entity": "sensor.formicarium_feuchte"})})
	if r.Results[0].Status != "applied" {
		t.Fatalf("sensor: %+v", r.Results[0])
	}
	bad := admin.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "sensors", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"name": "X", "kind": "home_assistant", "ha_temperature_entity": "kein entity"})})
	if bad.Results[0].Status != "rejected" {
		t.Fatalf("invalid entity accepted: %+v", bad.Results[0])
	}
	if n, err := env.Svc.HASensorSync(ctx); err != nil || n != 1 {
		t.Fatalf("ha sync: %d %v", n, err)
	}
	if n, _ := env.Svc.HASensorSync(ctx); n != 0 {
		t.Fatalf("same value stored twice: %d", n)
	}
	if v := env.Count(t, `SELECT round(value)::int FROM sensor_readings WHERE sensor_id = $1 AND metric = 'temperature'`, sensor); v != 25 {
		t.Fatalf("temperature: %d", v)
	}
}
