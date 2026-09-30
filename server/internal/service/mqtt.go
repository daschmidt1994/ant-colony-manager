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
// (owner or carer – like the calendar subscription) and those of every user
// who switched it on for themselves (mqtt_members).
//
// Home Assistant can act, too: a button per care plan ("done") and a winter
// rest switch per colony. Commands are carried out as a sending user who
// may edit the colony.
//
// Topics, all retained:
//
//	<prefix>/device/acm_<colony id>/config   discovery, one message per colony
//	<prefix>/device/acm_summary/config       totals
//	ant-colony-manager/colony/<id>/state     state of a colony (JSON)
//	ant-colony-manager/state                 totals (JSON)
//	ant-colony-manager/status                online / offline (last will)
//	ant-colony-manager/colony/<id>/done      ← care plan id: care done
//	ant-colony-manager/colony/<id>/hibernation/set  ← ON / OFF

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
	// Home Assistant REST API for sensor values (optional)
	HAURL      string `json:"ha_url,omitempty"`
	HATokenEnc string `json:"ha_token_enc,omitempty"`
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
	Members     []string   `json:"members"`         // other users who send their colonies
	Status      MQTTStatus `json:"status"`
	// Home Assistant REST API for sensor values
	HAURL      string  `json:"ha_url"`
	HAToken    *string `json:"ha_token,omitempty"` // input: nil = keep, "" = remove
	HATokenSet bool    `json:"ha_token_set"`
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
	// Subscribe: topic filter → handler (commands from Home Assistant)
	Subscribe map[string]func(topic string, payload []byte)
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
	haKick  chan struct{}
}

func (s *Service) haKick() {
	select {
	case s.mqtt.haKick <- struct{}{}:
	default:
	}
}

// HARun reads Home Assistant sensors every 5 minutes (and after a change of
// the settings).
func (s *Service) HARun(ctx context.Context) {
	t := time.NewTicker(5 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-s.mqtt.haKick:
		}
		if _, err := s.HASensorSync(ctx); err != nil && ctx.Err() == nil {
			s.Log.Warn("home assistant sensors failed", "err", err)
		}
	}
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
		opts.Subscribe = map[string]func(string, []byte){
			mqttBase + "/colony/+/done":            s.mqttCommand,
			mqttBase + "/colony/+/hibernation/set": s.mqttCommand,
		}
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

	status, owners, err := s.mqttStatus(ctx, st)
	if err != nil {
		return err
	}
	lang := s.userLang(ctx, st.UserID)
	msgs := s.mqttMessages(st.Prefix, lang, status, owners)
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
//
// owners maps the owners of colonies that are not the administrator's to a
// short name for the entity IDs (sensor.acm_anna_colony_3_overdue) – colony
// numbers are counted per owner.
func (s *Service) mqttMessages(prefix, lang string, st *FeedStatus, owners map[uuid.UUID]string) []mqttMessage {
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
		ent := "acm_colony_" + strconv.Itoa(c.Number)
		if o := owners[c.OwnerID]; o != "" {
			ent = "acm_" + o + "_colony_" + strconv.Itoa(c.Number)
		}
		state := mqttBase + "/colony/" + c.ID.String() + "/state"
		cmps := map[string]any{
			"overdue":   count("overdue", "Überfällig", "mdi:ant", id+"_overdue", ent+"_overdue"),
			"due_today": count("due_today", "Heute fällig", "mdi:ant", id+"_due_today", ent+"_due_today"),
			"next_due": map[string]any{"platform": "sensor", "name": tl(lang, "Nächste Pflege"), "device_class": "timestamp",
				"unique_id": id + "_next_due", "default_entity_id": "sensor." + ent + "_next_due",
				"value_template":           "{{ value_json.next_due_at }}",
				"json_attributes_topic":    state,
				"json_attributes_template": "{{ value_json.next_due | tojson }}"},
			"next_task": map[string]any{"platform": "sensor", "name": tl(lang, "Nächste Aufgabe"), "icon": "mdi:clipboard-list",
				"unique_id": id + "_next_task", "default_entity_id": "sensor." + ent + "_next_task",
				"value_template": "{{ value_json.next_task }}"},
			"hibernation": map[string]any{"platform": "binary_sensor", "name": tl(lang, "Winterruhe"), "icon": "mdi:snowflake",
				"unique_id": id + "_hibernation", "default_entity_id": "binary_sensor." + ent + "_hibernation",
				"value_template": "{{ 'ON' if value_json.hibernating else 'OFF' }}"},
			// switch: start or end the winter rest from Home Assistant
			"hibernation_switch": map[string]any{"platform": "switch", "name": tl(lang, "Winterruhe an/aus"), "icon": "mdi:snowflake",
				"unique_id": id + "_hibernation_switch", "default_entity_id": "switch." + ent + "_hibernation",
				"command_topic":  mqttBase + "/colony/" + c.ID.String() + "/hibernation/set",
				"value_template": "{{ 'ON' if value_json.hibernating else 'OFF' }}",
				"payload_on":     "ON", "payload_off": "OFF", "state_on": "ON", "state_off": "OFF"},
		}
		// one "done" button per care plan
		for _, t := range c.Care {
			key := t.TaskType
			if key == "custom" {
				key = "custom_" + strings.ReplaceAll(t.ScheduleID.String(), "-", "")[:8]
			}
			cmps["done_"+key] = map[string]any{"platform": "button", "name": tl(lang, "%s erledigt", taskLabel(lang, t)),
				"icon": "mdi:check-circle-outline", "unique_id": id + "_done_" + t.ScheduleID.String(),
				"default_entity_id": "button." + ent + "_" + key + "_done",
				"command_topic":     mqttBase + "/colony/" + c.ID.String() + "/done",
				"payload_press":     t.ScheduleID.String()}
		}
		if c.Temperature != nil {
			cmps["temperature"] = map[string]any{"platform": "sensor", "name": tl(lang, "Temperatur"),
				"device_class": "temperature", "unit_of_measurement": "°C", "state_class": "measurement",
				"unique_id": id + "_temperature", "default_entity_id": "sensor." + ent + "_temperature",
				"value_template": "{{ value_json.temperature }}"}
		}
		if c.Humidity != nil {
			cmps["humidity"] = map[string]any{"platform": "sensor", "name": tl(lang, "Luftfeuchtigkeit"),
				"device_class": "humidity", "unit_of_measurement": "%", "state_class": "measurement",
				"unique_id": id + "_humidity", "default_entity_id": "sensor." + ent + "_humidity",
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

// mqttSenders: the administrator who set up the broker plus every user who
// switched Home Assistant on for themselves.
func (s *Service) mqttSenders(ctx context.Context, st storedMQTT) ([]uuid.UUID, error) {
	rows, err := s.Pool.Query(ctx, `SELECT m.user_id FROM mqtt_members m JOIN users u ON u.id = m.user_id
		WHERE u.disabled_at IS NULL ORDER BY m.created_at`)
	if err != nil {
		return nil, err
	}
	users, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return nil, err
	}
	if st.UserID != uuid.Nil && !slices.Contains(users, st.UserID) {
		users = append([]uuid.UUID{st.UserID}, users...)
	}
	return users, nil
}

// mqttStatus: the colonies of all senders (each once) with totals, and a
// short name per owner of colonies that are not the administrator's.
func (s *Service) mqttStatus(ctx context.Context, st storedMQTT) (*FeedStatus, map[uuid.UUID]string, error) {
	users, err := s.mqttSenders(ctx, st)
	if err != nil {
		return nil, nil, err
	}
	out := &FeedStatus{GeneratedAt: s.Now().UTC(), Colonies: []FeedColony{}}
	seen := map[uuid.UUID]bool{}
	var others []uuid.UUID
	for _, u := range users {
		one, err := s.colonyStatus(ctx, u)
		if err != nil {
			return nil, nil, err
		}
		for _, c := range one.Colonies {
			if seen[c.ID] {
				continue
			}
			seen[c.ID] = true
			out.Colonies = append(out.Colonies, c)
			out.Overdue += c.Overdue
			out.DueToday += c.DueToday
			if c.Hibernating {
				out.Hibernating++
			}
			if c.OwnerID != st.UserID && !slices.Contains(others, c.OwnerID) {
				others = append(others, c.OwnerID)
			}
		}
	}
	owners := map[uuid.UUID]string{}
	if len(others) > 0 {
		rows, err := s.Pool.Query(ctx, `SELECT id, display_name FROM users WHERE id = ANY($1)`, others)
		if err != nil {
			return nil, nil, err
		}
		var id uuid.UUID
		var name string
		if _, err := pgx.ForEachRow(rows, []any{&id, &name}, func() error {
			owners[id] = entitySlug(name, id)
			return nil
		}); err != nil {
			return nil, nil, err
		}
	}
	return out, owners, nil
}

// entitySlug: lower-case letters and digits for entity IDs ("Anna M." → anna_m).
func entitySlug(name string, id uuid.UUID) string {
	r := strings.NewReplacer("ä", "ae", "ö", "oe", "ü", "ue", "ß", "ss")
	var b strings.Builder
	for _, ch := range r.Replace(strings.ToLower(name)) {
		switch {
		case ch >= 'a' && ch <= 'z', ch >= '0' && ch <= '9':
			b.WriteRune(ch)
		case b.Len() > 0 && !strings.HasSuffix(b.String(), "_"):
			b.WriteByte('_')
		}
	}
	slug := strings.Trim(b.String(), "_")
	if slug == "" {
		slug = "user_" + strings.ReplaceAll(id.String(), "-", "")[:6]
	}
	if len(slug) > 20 {
		slug = strings.Trim(slug[:20], "_")
	}
	return slug
}

// mqttCommand carries out a button press or switch from Home Assistant. It
// runs as a sending user who may edit the colony.
func (s *Service) mqttCommand(topic string, payload []byte) {
	parts := strings.Split(topic, "/") // ant-colony-manager/colony/<id>/done | …/hibernation/set
	if len(parts) < 4 {
		return
	}
	colony, err := uuid.Parse(parts[2])
	if err != nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := s.runMQTTCommand(ctx, colony, parts[3], strings.TrimSpace(string(payload))); err != nil {
			s.Log.Warn("home assistant command failed", "topic", topic, "err", err)
			return
		}
		s.mqttKick()
	}()
}

func (s *Service) runMQTTCommand(ctx context.Context, colony uuid.UUID, cmd, payload string) error {
	st, err := s.loadMQTT(ctx)
	if err != nil || !st.Enabled {
		return err
	}
	users, err := s.mqttSenders(ctx, st)
	if err != nil {
		return err
	}
	var user uuid.UUID
	err = s.Pool.QueryRow(ctx, `SELECT user_id FROM colony_members
		WHERE colony_id = $1 AND user_id = ANY($2) AND role IN ('owner', 'editor') AND deleted_at IS NULL
		ORDER BY role = 'owner' DESC LIMIT 1`, colony, users).Scan(&user)
	if errors.Is(err, pgx.ErrNoRows) {
		return errors.New("colony is not sent to Home Assistant or may not be edited")
	}
	if err != nil {
		return err
	}
	actor := Actor{UserID: user}
	switch cmd {
	case "done":
		schedule, err := uuid.Parse(payload)
		if err != nil {
			return fmt.Errorf("invalid care plan %q", payload)
		}
		var ok bool
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM care_schedules WHERE id = $1 AND colony_id = $2)`,
			schedule, colony).Scan(&ok); err != nil || !ok {
			return fmt.Errorf("care plan %s does not belong to the colony", schedule)
		}
		_, err = s.MarkCareDone(ctx, actor, schedule)
		return err
	case "hibernation":
		if payload != "ON" && payload != "OFF" {
			return fmt.Errorf("invalid switch value %q", payload)
		}
		_, err := s.SetHibernation(ctx, actor, colony, payload == "ON")
		return err
	}
	return nil
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
	out := &MQTTSettings{Enabled: st.Enabled, URL: st.URL, User: st.User, PasswordSet: st.PasswordEnc != "", Prefix: st.Prefix,
		HAURL: st.HAURL, HATokenSet: st.HATokenEnc != "", Members: []string{}}
	rows, err := s.Pool.Query(ctx, `SELECT u.display_name FROM mqtt_members m JOIN users u ON u.id = m.user_id
		WHERE m.user_id <> $1 ORDER BY m.created_at`, st.UserID)
	if err != nil {
		return nil, err
	}
	if out.Members, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return nil, err
	}
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
	in.HAURL = strings.TrimRight(strings.TrimSpace(in.HAURL), "/")
	if in.HAURL != "" {
		if _, err := newHAClient(in.HAURL, ""); err != nil {
			return nil, err
		}
	}
	if in.HAToken != nil && (strings.ContainsAny(*in.HAToken, " \r\n") || len(*in.HAToken) > 1000) {
		return nil, Invalid("ha_token", "invalid access token")
	}
	st := storedMQTT{Enabled: in.Enabled, URL: u, User: in.User, PasswordEnc: old.PasswordEnc, Prefix: in.Prefix, UserID: actor.UserID,
		HAURL: in.HAURL, HATokenEnc: old.HATokenEnc}
	if in.HAToken != nil {
		st.HATokenEnc = ""
		if *in.HAToken != "" {
			if st.HATokenEnc, err = s.encryptSecret(*in.HAToken); err != nil {
				return nil, err
			}
		}
	}
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
	s.haKick()
	return s.GetMQTTSettings(ctx, actor)
}

// HomeAssistantMe is a user's own choice to send their colonies.
type HomeAssistantMe struct {
	Enabled   bool `json:"enabled"`   // own colonies are sent
	Available bool `json:"available"` // the administrator set up Home Assistant
	Always    bool `json:"always"`    // this user set it up – their colonies are always sent
}

func (s *Service) GetHomeAssistantMe(ctx context.Context, actor Actor) (*HomeAssistantMe, error) {
	st, err := s.loadMQTT(ctx)
	if err != nil {
		return nil, err
	}
	out := &HomeAssistantMe{Available: st.Enabled && st.URL != "", Always: st.UserID == actor.UserID}
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM mqtt_members WHERE user_id = $1)`, actor.UserID).
		Scan(&out.Enabled); err != nil {
		return nil, err
	}
	out.Enabled = out.Enabled || out.Always
	return out, nil
}

// SetHomeAssistantMe switches sending the own colonies on or off.
func (s *Service) SetHomeAssistantMe(ctx context.Context, actor Actor, on bool) (*HomeAssistantMe, error) {
	var err error
	if on {
		_, err = s.Pool.Exec(ctx, `INSERT INTO mqtt_members (user_id) VALUES ($1) ON CONFLICT DO NOTHING`, actor.UserID)
	} else {
		_, err = s.Pool.Exec(ctx, `DELETE FROM mqtt_members WHERE user_id = $1`, actor.UserID)
	}
	if err != nil {
		return nil, err
	}
	s.mqttKick()
	return s.GetHomeAssistantMe(ctx, actor)
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
