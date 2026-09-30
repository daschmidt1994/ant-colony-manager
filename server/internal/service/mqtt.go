package service

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

// Home Assistant via MQTT: the server announces every colony as a device
// (MQTT discovery) and keeps its state up to date. A new colony shows up in
// Home Assistant by itself; archived, handed over or deleted colonies are
// removed again. The administrator sets up the broker in the app
// (Server-Verwaltung); sent are the colonies that administrator cares for
// (owner or carer – like the calendar subscription).
//
// Topics, all retained:
//
//	<prefix>/device/acm_<colony id>/config   discovery, one message per colony
//	<prefix>/device/acm_summary/config       totals
//	ant-colony-manager/colony/<id>/state     state of a colony (JSON)
//	ant-colony-manager/state                 totals (JSON)
//	ant-colony-manager/status                online / offline (last will)

const (
	mqttKey       = "mqtt"
	mqttStateKey  = "mqtt_state"
	mqttBase      = "ant-colony-manager"
	mqttAvailable = mqttBase + "/status"
	mqttSummaryID = "acm_summary"
)

type storedMQTT struct {
	Enabled     bool      `json:"enabled"`
	URL         string    `json:"url"`
	User        string    `json:"user"`
	PasswordEnc string    `json:"password_enc,omitempty"`
	Prefix      string    `json:"prefix"`
	UserID      uuid.UUID `json:"user_id"` // whose colonies are sent
}

// mqttSent is what Home Assistant was told (kept across restarts, so that
// colonies that went away meanwhile are removed there too).
type mqttSent struct {
	Prefix  string   `json:"prefix"`
	Devices []string `json:"devices"`
}

// MQTTStatus describes the connection right now.
type MQTTStatus struct {
	Connected   bool       `json:"connected"`
	LastSync    *time.Time `json:"last_sync,omitempty"`
	LastError   string     `json:"last_error,omitempty"`
	LastErrorAt *time.Time `json:"last_error_at,omitempty"`
	Colonies    int        `json:"colonies"`
}

// MQTTSettings is the admin API shape; the password is write-only.
type MQTTSettings struct {
	Enabled     bool       `json:"enabled"`
	URL         string     `json:"url"`
	User        string     `json:"user"`
	Password    *string    `json:"password,omitempty"` // input: nil = keep, "" = remove
	PasswordSet bool       `json:"password_set"`
	Prefix      string     `json:"prefix"`
	Owner       string     `json:"owner,omitempty"` // whose colonies are sent (display name)
	Status      MQTTStatus `json:"status"`
}

// MQTTConn is what the publisher needs from a broker connection. Messages
// are sent retained with QoS 1.
type MQTTConn interface {
	Publish(topic string, payload []byte) error
	Connected() bool
	Close()
}

// MQTTOptions for MQTTDial. Without WillTopic the connection is a plain one
// (connection test): no last will, no online message, no subscription.
type MQTTOptions struct {
	URL, User, Password, ClientID string
	WillTopic                     string
	HAStatusTopic                 string // Home Assistant announces its (re)start here
	OnConnect                     func() // after every (re)connect
	OnHAOnline                    func()
}

type mqttState struct {
	syncMu  sync.Mutex // one sync at a time
	mu      sync.Mutex // guards the fields below
	conn    MQTTConn
	connKey string
	cache   map[string]string // topic -> payload sent on this connection
	status  MQTTStatus
	lastLog string
	kick    chan struct{}
}

func (s *Service) mqttKick() {
	select {
	case s.mqtt.kick <- struct{}{}:
	default:
	}
}

// MQTTRun keeps Home Assistant up to date: every 30 seconds, and right after
// a change of the settings or of colony data.
func (s *Service) MQTTRun(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		if err := s.MQTTSync(ctx); err != nil && ctx.Err() == nil {
			s.mqttLog(err)
		}
		select {
		case <-ctx.Done():
			s.mqttShutdown()
			return
		case <-t.C:
		case <-s.mqtt.kick:
			// several changes in a row (a sync from the app) → one update
			select {
			case <-ctx.Done():
			case <-time.After(2 * time.Second):
			}
		}
	}
}

// mqttLog logs an error once, not every 30 seconds.
func (s *Service) mqttLog(err error) {
	s.mqtt.mu.Lock()
	defer s.mqtt.mu.Unlock()
	if err.Error() != s.mqtt.lastLog {
		s.mqtt.lastLog = err.Error()
		s.Log.Warn("home assistant (mqtt) update failed", "err", err)
	}
}

func (s *Service) mqttShutdown() {
	s.mqtt.syncMu.Lock()
	defer s.mqtt.syncMu.Unlock()
	s.mqttDisconnect()
}

// mqttDisconnect marks the entities unavailable and closes the connection.
func (s *Service) mqttDisconnect() {
	s.mqtt.mu.Lock()
	conn := s.mqtt.conn
	s.mqtt.conn, s.mqtt.connKey, s.mqtt.cache = nil, "", nil
	s.mqtt.mu.Unlock()
	if conn != nil {
		if conn.Connected() {
			_ = conn.Publish(mqttAvailable, []byte("offline"))
		}
		conn.Close()
	}
}

func (s *Service) mqttSetStatus(f func(st *MQTTStatus)) {
	s.mqtt.mu.Lock()
	defer s.mqtt.mu.Unlock()
	f(&s.mqtt.status)
}

func (s *Service) mqttFail(err error) error {
	now := s.Now()
	s.mqttSetStatus(func(st *MQTTStatus) {
		st.Connected, st.LastError, st.LastErrorAt = false, err.Error(), &now
	})
	return err
}

func (s *Service) loadMQTT(ctx context.Context) (storedMQTT, error) {
	var st storedMQTT
	_, err := s.loadJSONSetting(ctx, mqttKey, &st)
	if st.Prefix == "" {
		st.Prefix = "homeassistant"
	}
	return st, err
}

func (s *Service) mqttOptions(st storedMQTT) (MQTTOptions, error) {
	pw, err := s.decryptSecret(st.PasswordEnc)
	if err != nil {
		return MQTTOptions{}, fmt.Errorf("stored MQTT password cannot be decrypted (INSTANCE_SECRET changed?): %w", err)
	}
	id := hex.EncodeToString(auth.HMAC(s.Cfg.InstanceSecret, "acm:mqtt-client"))[:10]
	return MQTTOptions{URL: st.URL, User: st.User, Password: pw, ClientID: "ant-colony-manager-" + id}, nil
}

// MQTTSync connects if needed and sends what changed. Colonies that are no
// longer there (or everything, when switched off) are removed from Home Assistant.
func (s *Service) MQTTSync(ctx context.Context) error {
	s.mqtt.syncMu.Lock()
	defer s.mqtt.syncMu.Unlock()
	st, err := s.loadMQTT(ctx)
	if err != nil {
		return err
	}
	var sent mqttSent
	if _, err := s.loadJSONSetting(ctx, mqttStateKey, &sent); err != nil {
		return err
	}
	active := st.Enabled && st.URL != ""
	key := strings.Join([]string{st.URL, st.User, st.PasswordEnc}, "\x00")

	s.mqtt.mu.Lock()
	conn, connKey := s.mqtt.conn, s.mqtt.connKey
	s.mqtt.mu.Unlock()

	// Another broker: tell the old one goodbye first.
	if conn != nil && connKey != key {
		if conn.Connected() && len(sent.Devices) > 0 {
			if err := s.mqttRemove(conn, sent.Prefix, sent.Devices); err == nil {
				sent.Devices = nil
				_ = s.saveJSONSetting(ctx, mqttStateKey, sent)
			}
		}
		s.mqttDisconnect()
		conn = nil
	}
	if !active && len(sent.Devices) == 0 {
		s.mqttDisconnect()
		s.mqttSetStatus(func(ms *MQTTStatus) { *ms = MQTTStatus{} })
		return nil
	}
	if st.URL == "" {
		return nil // switched off without a broker: nothing we could remove
	}
	if conn == nil {
		opts, err := s.mqttOptions(st)
		if err != nil {
			return s.mqttFail(err)
		}
		opts.WillTopic = mqttAvailable
		opts.HAStatusTopic = st.Prefix + "/status"
		opts.OnConnect = func() {
			s.mqtt.mu.Lock()
			s.mqtt.cache = map[string]string{}
			s.mqtt.mu.Unlock()
			s.mqttKick()
		}
		opts.OnHAOnline = opts.OnConnect // Home Assistant restarted: send everything again
		if conn, err = s.MQTTDial(ctx, opts); err != nil {
			return s.mqttFail(err)
		}
		s.mqtt.mu.Lock()
		s.mqtt.conn, s.mqtt.connKey, s.mqtt.cache = conn, key, map[string]string{}
		s.mqtt.mu.Unlock()
	}
	if !conn.Connected() {
		return s.mqttFail(errors.New("connection to the MQTT broker lost – reconnecting"))
	}

	if !active {
		// switched off: remove the devices, then disconnect
		if err := s.mqttRemove(conn, sent.Prefix, sent.Devices); err != nil {
			return s.mqttFail(err)
		}
		if err := s.saveJSONSetting(ctx, mqttStateKey, mqttSent{}); err != nil {
			return err
		}
		s.mqttDisconnect()
		s.mqttSetStatus(func(ms *MQTTStatus) { *ms = MQTTStatus{} })
		return nil
	}

	status, err := s.colonyStatus(ctx, st.UserID)
	if err != nil {
		return err
	}
	lang := s.userLang(ctx, st.UserID)
	msgs := s.mqttMessages(st.Prefix, lang, status)
	for _, m := range msgs {
		if err := s.mqttPublish(conn, m.topic, m.payload); err != nil {
			return s.mqttFail(err)
		}
	}
	devices := []string{mqttSummaryID}
	for _, c := range status.Colonies {
		devices = append(devices, "acm_"+c.ID.String())
	}
	var gone []string
	for _, d := range sent.Devices {
		if sent.Prefix != st.Prefix || !slices.Contains(devices, d) {
			gone = append(gone, d)
		}
	}
	if err := s.mqttRemove(conn, sent.Prefix, gone); err != nil {
		return s.mqttFail(err)
	}
	if sent.Prefix != st.Prefix || !slices.Equal(sent.Devices, devices) {
		if err := s.saveJSONSetting(ctx, mqttStateKey, mqttSent{Prefix: st.Prefix, Devices: devices}); err != nil {
			return err
		}
	}
	now := s.Now()
	s.mqttSetStatus(func(ms *MQTTStatus) {
		ms.Connected, ms.LastSync, ms.Colonies, ms.LastError, ms.LastErrorAt = true, &now, len(status.Colonies), "", nil
	})
	s.mqtt.mu.Lock()
	s.mqtt.lastLog = ""
	s.mqtt.mu.Unlock()
	return nil
}

// mqttPublish sends a message unless this connection already sent exactly it.
func (s *Service) mqttPublish(conn MQTTConn, topic string, payload []byte) error {
	s.mqtt.mu.Lock()
	prev, known := s.mqtt.cache[topic]
	s.mqtt.mu.Unlock()
	if known && prev == string(payload) {
		return nil
	}
	if err := conn.Publish(topic, payload); err != nil {
		return err
	}
	s.mqtt.mu.Lock()
	if s.mqtt.cache != nil {
		s.mqtt.cache[topic] = string(payload)
	}
	s.mqtt.mu.Unlock()
	return nil
}

// mqttRemove deletes devices in Home Assistant (empty retained config) and
// their retained state.
func (s *Service) mqttRemove(conn MQTTConn, prefix string, devices []string) error {
	for _, d := range devices {
		state := mqttBase + "/state"
		if id, ok := strings.CutPrefix(d, "acm_"); ok && d != mqttSummaryID {
			state = mqttBase + "/colony/" + id + "/state"
		}
		for _, topic := range []string{prefix + "/device/" + d + "/config", state} {
			if err := conn.Publish(topic, nil); err != nil {
				return err
			}
			s.mqtt.mu.Lock()
			delete(s.mqtt.cache, topic)
			s.mqtt.mu.Unlock()
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Messages

type mqttMessage struct {
	topic   string
	payload []byte
}

func mqttJSON(v any) []byte {
	b, _ := json.Marshal(v) // maps: sorted keys, so equal content gives equal bytes
	return b
}

// mqttMessages: discovery and state for the totals and every colony. Entity
// IDs contain the colony number (sensor.acm_colony_3_overdue); Home Assistant
// keeps them when a colony is renamed.
func (s *Service) mqttMessages(prefix, lang string, st *FeedStatus) []mqttMessage {
	origin := map[string]any{"name": "Ant Colony Manager", "support_url": "https://github.com/daschmidt1994/ant-colony-manager"}
	// unique IDs contain the colony id (numbers may change), entity IDs the number
	count := func(key, name, icon, uniqueID, entity string) map[string]any {
		return map[string]any{"platform": "sensor", "name": tl(lang, name), "icon": icon, "state_class": "measurement",
			"unique_id": uniqueID, "default_entity_id": "sensor." + entity, "value_template": "{{ value_json." + key + " }}"}
	}

	summaryState := mqttBase + "/state"
	msgs := []mqttMessage{{
		topic: prefix + "/device/" + mqttSummaryID + "/config",
		payload: mqttJSON(map[string]any{
			"device": map[string]any{"identifiers": []string{mqttSummaryID}, "name": tl(lang, "Ameisen"),
				"manufacturer": "Ant Colony Manager", "model": "Server", "configuration_url": s.publicURL() + "/"},
			"origin":             origin,
			"state_topic":        summaryState,
			"availability_topic": mqttAvailable,
			"qos":                1,
			"components": map[string]any{
				"overdue":     count("overdue", "Überfällig", "mdi:ant", "acm_overdue", "acm_overdue"),
				"due_today":   count("due_today", "Heute fällig", "mdi:ant", "acm_due_today", "acm_due_today"),
				"hibernating": count("hibernating", "In Winterruhe", "mdi:snowflake", "acm_hibernating", "acm_hibernating"),
				"colonies":    count("colonies", "Kolonien", "mdi:ant", "acm_colonies", "acm_colonies"),
			},
		}),
	}, {
		topic: summaryState,
		payload: mqttJSON(map[string]any{"overdue": st.Overdue, "due_today": st.DueToday,
			"hibernating": st.Hibernating, "colonies": len(st.Colonies)}),
	}}

	for _, c := range st.Colonies {
		id := "acm_" + c.ID.String()
		n := strconv.Itoa(c.Number)
		state := mqttBase + "/colony/" + c.ID.String() + "/state"
		cmps := map[string]any{
			"overdue":   count("overdue", "Überfällig", "mdi:ant", id+"_overdue", "acm_colony_"+n+"_overdue"),
			"due_today": count("due_today", "Heute fällig", "mdi:ant", id+"_due_today", "acm_colony_"+n+"_due_today"),
			"next_due": map[string]any{"platform": "sensor", "name": tl(lang, "Nächste Pflege"), "device_class": "timestamp",
				"unique_id": id + "_next_due", "default_entity_id": "sensor.acm_colony_" + n + "_next_due",
				"value_template":           "{{ value_json.next_due_at }}",
				"json_attributes_topic":    state,
				"json_attributes_template": "{{ value_json.next_due | tojson }}"},
			"next_task": map[string]any{"platform": "sensor", "name": tl(lang, "Nächste Aufgabe"), "icon": "mdi:clipboard-list",
				"unique_id": id + "_next_task", "default_entity_id": "sensor.acm_colony_" + n + "_next_task",
				"value_template": "{{ value_json.next_task }}"},
			"hibernation": map[string]any{"platform": "binary_sensor", "name": tl(lang, "Winterruhe"), "icon": "mdi:snowflake",
				"unique_id": id + "_hibernation", "default_entity_id": "binary_sensor.acm_colony_" + n + "_hibernation",
				"value_template": "{{ 'ON' if value_json.hibernating else 'OFF' }}"},
		}
		if c.Temperature != nil {
			cmps["temperature"] = map[string]any{"platform": "sensor", "name": tl(lang, "Temperatur"),
				"device_class": "temperature", "unit_of_measurement": "°C", "state_class": "measurement",
				"unique_id": id + "_temperature", "default_entity_id": "sensor.acm_colony_" + n + "_temperature",
				"value_template": "{{ value_json.temperature }}"}
		}
		if c.Humidity != nil {
			cmps["humidity"] = map[string]any{"platform": "sensor", "name": tl(lang, "Luftfeuchtigkeit"),
				"device_class": "humidity", "unit_of_measurement": "%", "state_class": "measurement",
				"unique_id": id + "_humidity", "default_entity_id": "sensor.acm_colony_" + n + "_humidity",
				"value_template": "{{ value_json.humidity }}"}
		}
		model := c.Species
		if model == "" {
			model = tl(lang, "Ameisenkolonie")
		}
		msgs = append(msgs, mqttMessage{
			topic: prefix + "/device/" + id + "/config",
			payload: mqttJSON(map[string]any{
				"device": map[string]any{"identifiers": []string{id}, "name": fmt.Sprintf("%s (#%d)", c.Name, c.Number),
					"manufacturer": "Ant Colony Manager", "model": model, "via_device": mqttSummaryID,
					"configuration_url": s.publicURL() + "/colonies/" + c.ID.String()},
				"origin":             origin,
				"state_topic":        state,
				"availability_topic": mqttAvailable,
				"qos":                1,
				"components":         cmps,
			}),
		})

		next := map[string]any{} // attributes must be an object, also without due care
		var nextAt *time.Time
		var nextTask *string
		if d := c.NextDue; d != nil {
			next = map[string]any{"task": d.Task, "days": d.Days, "state": d.State}
			nextAt, nextTask = &d.At, &d.Task
		}
		msgs = append(msgs, mqttMessage{topic: state, payload: mqttJSON(map[string]any{
			"name": c.Name, "number": c.Number, "species": c.Species, "status": c.Status,
			"overdue": c.Overdue, "due_today": c.DueToday, "hibernating": c.Hibernating,
			"next_due_at": nextAt, "next_task": nextTask, "next_due": next,
			"temperature": c.Temperature, "humidity": c.Humidity, "measured_at": c.MeasuredAt,
		})})
	}
	return msgs
}

// ---------------------------------------------------------------------------
// Settings (admin)

func (s *Service) GetMQTTSettings(ctx context.Context, actor Actor) (*MQTTSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	st, err := s.loadMQTT(ctx)
	if err != nil {
		return nil, err
	}
	out := &MQTTSettings{Enabled: st.Enabled, URL: st.URL, User: st.User, PasswordSet: st.PasswordEnc != "", Prefix: st.Prefix}
	if st.UserID != uuid.Nil {
		err := s.Pool.QueryRow(ctx, `SELECT display_name FROM users WHERE id = $1`, st.UserID).Scan(&out.Owner)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	s.mqtt.mu.Lock()
	out.Status = s.mqtt.status
	s.mqtt.mu.Unlock()
	return out, nil
}

// SetMQTTSettings saves the broker; from now on the colonies of the
// administrator who saved it are sent.
func (s *Service) SetMQTTSettings(ctx context.Context, actor Actor, in MQTTSettings, meta ClientMeta) (*MQTTSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	u, err := normalizeMQTTURL(in.URL)
	if err != nil {
		return nil, err
	}
	if u == "" && in.Enabled {
		return nil, Invalid("url", "enter the MQTT broker, e.g. mqtt://192.168.1.10:1883")
	}
	in.User = strings.TrimSpace(in.User)
	if strings.ContainsAny(in.User, "\r\n") || len(in.User) > 320 ||
		(in.Password != nil && (strings.ContainsAny(*in.Password, "\r\n") || len(*in.Password) > 500)) {
		return nil, Invalid("user", "invalid user or password")
	}
	in.Prefix = strings.Trim(strings.TrimSpace(in.Prefix), "/")
	if in.Prefix == "" {
		in.Prefix = "homeassistant"
	}
	if strings.ContainsAny(in.Prefix, "+# \r\n") || len(in.Prefix) > 100 {
		return nil, Invalid("prefix", "the discovery prefix must not contain spaces, + or # (default: homeassistant)")
	}
	old, err := s.loadMQTT(ctx)
	if err != nil {
		return nil, err
	}
	st := storedMQTT{Enabled: in.Enabled, URL: u, User: in.User, PasswordEnc: old.PasswordEnc, Prefix: in.Prefix, UserID: actor.UserID}
	if in.Password != nil {
		st.PasswordEnc = ""
		if *in.Password != "" {
			if st.PasswordEnc, err = s.encryptSecret(*in.Password); err != nil {
				return nil, err
			}
		}
	}
	if err := s.saveJSONSetting(ctx, mqttKey, st); err != nil {
		return nil, err
	}
	s.Audit(ctx, &actor.UserID, "mqtt_settings_changed", "", map[string]any{"url": st.URL, "enabled": st.Enabled}, meta.IP)
	s.mqttKick()
	return s.GetMQTTSettings(ctx, actor)
}

// TestMQTT connects to the saved broker once (address and login).
func (s *Service) TestMQTT(ctx context.Context, actor Actor) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	st, err := s.loadMQTT(ctx)
	if err != nil {
		return err
	}
	if st.URL == "" {
		return Invalid("url", "enter and save the MQTT broker first")
	}
	opts, err := s.mqttOptions(st)
	if err != nil {
		return err
	}
	opts.ClientID += "-test"
	conn, err := s.MQTTDial(ctx, opts)
	if err != nil {
		return &Problem{Status: 502, Code: "mqtt.failed", Title: err.Error()}
	}
	conn.Close()
	return nil
}

// normalizeMQTTURL accepts "host", "host:port" or mqtt(s)://host[:port] and
// returns mqtt(s)://host:port ("" stays "").
func normalizeMQTTURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if !strings.Contains(raw, "://") {
		raw = "mqtt://" + raw
	}
	bad := Invalid("url", "enter the broker as host or mqtt://host:1883 (mqtts:// for TLS)")
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "mqtt" && u.Scheme != "mqtts") || u.Hostname() == "" || u.User != nil ||
		(u.Path != "" && u.Path != "/") || u.RawQuery != "" || len(raw) > 300 {
		return "", bad
	}
	port := u.Port()
	switch {
	case port == "" && u.Scheme == "mqtts":
		port = "8883"
	case port == "":
		port = "1883"
	default:
		if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
			return "", bad
		}
	}
	return u.Scheme + "://" + net.JoinHostPort(u.Hostname(), port), nil
}
