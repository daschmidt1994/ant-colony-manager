package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Sensors of kind "home_assistant" get their values from Home Assistant: the
// server reads the chosen entities every 5 minutes via the REST API (address
// and long-lived access token in the Home Assistant settings of the admin).
// Only sensors of users who send their colonies to Home Assistant (the
// administrator and mqtt_members) are read – the token belongs to the admin.

// haClient reads entity states from Home Assistant.
type haClient struct {
	base   *url.URL
	token  string
	client *http.Client
}

func newHAClient(raw, token string) (*haClient, error) {
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(raw), "/"))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" {
		return nil, Invalid("ha_url", "enter the Home Assistant address, e.g. http://192.168.1.10:8123")
	}
	return &haClient{base: u, token: token, client: &http.Client{Timeout: 20 * time.Second}}, nil
}

type haState struct {
	State       string    `json:"state"`
	LastUpdated time.Time `json:"last_updated"`
}

func (h *haClient) state(ctx context.Context, entity string) (*haState, error) {
	u := *h.base
	u.Path = strings.TrimRight(u.Path, "/") + "/api/states/" + entity
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+h.token)
	resp, err := h.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Home Assistant not reachable: %w", err)
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusUnauthorized, http.StatusForbidden:
		return nil, errors.New("Home Assistant refuses the access token")
	case http.StatusNotFound:
		return nil, fmt.Errorf("entity %s not found in Home Assistant", entity)
	default:
		return nil, fmt.Errorf("Home Assistant answers HTTP %d", resp.StatusCode)
	}
	var st haState
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&st); err != nil {
		return nil, fmt.Errorf("unreadable answer from Home Assistant: %w", err)
	}
	return &st, nil
}

// check verifies address and token (GET /api/ answers {"message": "API running."}).
func (h *haClient) check(ctx context.Context) error {
	u := *h.base
	u.Path = strings.TrimRight(u.Path, "/") + "/api/"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+h.token)
	resp, err := h.client.Do(req)
	if err != nil {
		return fmt.Errorf("Home Assistant not reachable: %w", err)
	}
	resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusUnauthorized, http.StatusForbidden:
		return errors.New("Home Assistant refuses the access token")
	}
	return fmt.Errorf("Home Assistant answers HTTP %d", resp.StatusCode)
}

func (s *Service) haClientFor(st storedMQTT) (*haClient, error) {
	if st.HAURL == "" || st.HATokenEnc == "" {
		return nil, nil
	}
	token, err := s.decryptSecret(st.HATokenEnc)
	if err != nil {
		return nil, fmt.Errorf("stored Home Assistant token cannot be decrypted (INSTANCE_SECRET changed?): %w", err)
	}
	return newHAClient(st.HAURL, token)
}

// TestHomeAssistant checks the saved address and access token.
func (s *Service) TestHomeAssistant(ctx context.Context, actor Actor) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	st, err := s.loadMQTT(ctx)
	if err != nil {
		return err
	}
	h, err := s.haClientFor(st)
	if err != nil {
		return err
	}
	if h == nil {
		return Invalid("ha_url", "enter and save the Home Assistant address and access token first")
	}
	if err := h.check(ctx); err != nil {
		return &Problem{Status: http.StatusBadGateway, Code: "home_assistant.failed", Title: err.Error()}
	}
	return nil
}

// HASensorSync reads every Home Assistant sensor once. Errors per sensor are
// logged and do not stop the others.
func (s *Service) HASensorSync(ctx context.Context) (int, error) {
	st, err := s.loadMQTT(ctx)
	if err != nil {
		return 0, err
	}
	h, err := s.haClientFor(st)
	if err != nil || h == nil {
		return 0, err
	}
	users, err := s.mqttSenders(ctx, st)
	if err != nil {
		return 0, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT id, owner_id, last_seen_at, ha_temperature_entity, ha_humidity_entity FROM sensors
		WHERE kind = 'home_assistant' AND active AND deleted_at IS NULL
		  AND (ha_temperature_entity IS NOT NULL OR ha_humidity_entity IS NOT NULL)`)
	if err != nil {
		return 0, err
	}
	type sensor struct {
		id, owner   uuid.UUID
		lastSeen    *time.Time
		temp, humid *string
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (sensor, error) {
		var x sensor
		err := r.Scan(&x.id, &x.owner, &x.lastSeen, &x.temp, &x.humid)
		return x, err
	})
	if err != nil {
		return 0, err
	}
	stored := 0
	for _, x := range list {
		if !slices.Contains(users, x.owner) {
			continue
		}
		var readings []SensorReading
		for metric, entity := range map[string]*string{"temperature": x.temp, "humidity": x.humid} {
			if entity == nil {
				continue
			}
			v, err := h.state(ctx, *entity)
			if err != nil {
				s.Log.Warn("home assistant sensor", "sensor", x.id, "entity", *entity, "err", err)
				continue
			}
			f, err := strconv.ParseFloat(v.State, 64)
			if err != nil { // "unavailable", "unknown"
				continue
			}
			at := v.LastUpdated
			if at.IsZero() || at.After(s.Now()) {
				at = s.Now()
			}
			readings = append(readings, SensorReading{Metric: metric, Value: f, MeasuredAt: at.UTC().Truncate(time.Second)})
		}
		if len(readings) == 0 {
			continue
		}
		n, err := s.storeReadings(ctx, x.id, x.lastSeen, readings)
		if err != nil {
			s.Log.Warn("home assistant sensor", "sensor", x.id, "err", err)
			continue
		}
		stored += n
	}
	return stored, nil
}
