package api_test

import (
	"context"
	"encoding/json"
	"errors"
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
