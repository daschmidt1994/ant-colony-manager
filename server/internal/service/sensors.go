package service

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

const maxSensorBatch = 500

var errBadSensorKey = &Problem{Status: 401, Code: "sensor.unauthorized", Title: "invalid sensor key"}

type SensorReading struct {
	Metric     string    `json:"metric"`
	Value      float64   `json:"value"`
	MeasuredAt time.Time `json:"measured_at"`
}

// SensorKeyPrefix extracts the lookup prefix of an "acm_sk_<prefix>_<secret>" key.
func SensorKeyPrefix(key string) (prefix, secret string, ok bool) {
	parts := strings.SplitN(key, "_", 4)
	if len(parts) != 4 || parts[0] != "acm" || parts[1] != "sk" || parts[2] == "" || parts[3] == "" {
		return "", "", false
	}
	return parts[2], parts[3], true
}

// IngestSensor stores readings for exactly the sensor that owns apiKey.
// Duplicate readings (same sensor, metric and time) are ignored.
func (s *Service) IngestSensor(ctx context.Context, apiKey string, sensorID uuid.UUID, readings []SensorReading) (int, error) {
	prefix, secret, ok := SensorKeyPrefix(apiKey)
	if !ok {
		return 0, errBadSensorKey
	}
	var id uuid.UUID
	var hash []byte
	var active bool
	var lastSeen *time.Time
	err := s.Pool.QueryRow(ctx, `SELECT id, api_key_hash, active, last_seen_at FROM sensors
		WHERE api_key_prefix = $1 AND deleted_at IS NULL`, prefix).Scan(&id, &hash, &active, &lastSeen)
	if errors.Is(err, pgx.ErrNoRows) {
		auth.HashToken(secret) // keep timing similar
		return 0, errBadSensorKey
	}
	if err != nil {
		return 0, err
	}
	if subtle.ConstantTimeCompare(auth.HashToken(secret), hash) != 1 || id != sensorID || !active {
		return 0, errBadSensorKey
	}
	if len(readings) == 0 || len(readings) > maxSensorBatch {
		return 0, Invalid("readings", "send 1–%d readings", maxSensorBatch)
	}
	now := s.Now()
	for i, r := range readings {
		switch r.Metric {
		case "temperature":
			if r.Value < -40 || r.Value > 80 {
				return 0, Invalid("readings", "reading %d: temperature out of range", i)
			}
		case "humidity":
			if r.Value < 0 || r.Value > 100 {
				return 0, Invalid("readings", "reading %d: humidity out of range", i)
			}
		default:
			return 0, Invalid("readings", "reading %d: metric must be temperature or humidity", i)
		}
		if r.MeasuredAt.IsZero() {
			readings[i].MeasuredAt = now
		} else if r.MeasuredAt.After(now.Add(maxFutureSkew)) {
			return 0, Invalid("readings", "reading %d: measured_at lies in the future", i)
		}
	}
	b, _ := json.Marshal(readings)
	tag, err := s.Pool.Exec(ctx, `INSERT INTO sensor_readings (sensor_id, metric, measured_at, value)
		SELECT $1, r.metric, r.measured_at, r.value
		FROM jsonb_to_recordset($2::jsonb) AS r(metric text, measured_at timestamptz, value numeric)
		ON CONFLICT DO NOTHING`, id, b)
	if err != nil {
		return 0, problemFromDB(err)
	}
	if err := s.checkSensorLimits(ctx, id, readings, now); err != nil {
		s.Log.Warn("sensor limit check failed", "sensor", id, "err", err)
	}
	// Throttle last_seen updates – every update is a synced change.
	if lastSeen == nil || now.Sub(*lastSeen) > 10*time.Minute {
		_, _ = s.Pool.Exec(ctx, `UPDATE sensors SET last_seen_at = now() WHERE id = $1`, id)
	}
	return int(tag.RowsAffected()), nil
}

type SensorBucket struct {
	Metric string    `json:"metric"`
	At     time.Time `json:"at"`
	Avg    float64   `json:"avg"`
	Min    float64   `json:"min"`
	Max    float64   `json:"max"`
	N      int       `json:"n"`
}

func (s *Service) SensorReadings(ctx context.Context, actor Actor, sensorID uuid.UUID, from, to time.Time, bucket time.Duration) ([]SensorBucket, error) {
	var owner uuid.UUID
	var colony *uuid.UUID
	err := s.Pool.QueryRow(ctx, `SELECT owner_id, colony_id FROM sensors WHERE id = $1 AND deleted_at IS NULL`, sensorID).Scan(&owner, &colony)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, NotFound("sensor")
	}
	if err != nil {
		return nil, err
	}
	if owner != actor.UserID {
		if colony == nil {
			return nil, NotFound("sensor")
		}
		if _, err := requireColony(ctx, s.Pool, actor, *colony, RoleViewer); err != nil {
			return nil, NotFound("sensor")
		}
	}
	if bucket < time.Minute {
		bucket = time.Hour
	}
	if to.Sub(from)/bucket > 5000 {
		return nil, Invalid("bucket", "too many buckets – choose a larger bucket or shorter range")
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT metric, date_bin($4::interval, measured_at, 'epoch'::timestamptz) AS b,
		       avg(value)::float8, min(value)::float8, max(value)::float8, count(*)
		FROM sensor_readings WHERE sensor_id = $1 AND measured_at >= $2 AND measured_at < $3
		GROUP BY metric, b ORDER BY b, metric`, sensorID, from, to, bucket)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (SensorBucket, error) {
		var x SensorBucket
		err := r.Scan(&x.Metric, &x.At, &x.Avg, &x.Min, &x.Max, &x.N)
		return x, err
	})
}

// RotateSensorKey issues a new key; the old one stops working immediately.
func (s *Service) RotateSensorKey(ctx context.Context, actor Actor, id uuid.UUID) (string, error) {
	prefix, secret := newSensorKey()
	tag, err := s.Pool.Exec(ctx, `UPDATE sensors SET api_key_prefix = $3, api_key_hash = $4
		WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL`, id, actor.UserID, prefix, auth.HashToken(secret))
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() == 0 {
		return "", NotFound("sensor")
	}
	return "acm_sk_" + prefix + "_" + secret, nil
}

// sensorAlertPause: one alert per sensor and metric at most this often.
const sensorAlertPause = 6 * time.Hour

// checkSensorLimits writes a „problem“ event into the colony's timeline when
// the newest reading of a metric is outside the sensor's limits. Old
// (back-filled) readings never alert.
func (s *Service) checkSensorLimits(ctx context.Context, sensor uuid.UUID, readings []SensorReading, now time.Time) error {
	var name string
	var colony *uuid.UUID
	var owner uuid.UUID
	var tMin, tMax, hMin, hMax *float64
	err := s.Pool.QueryRow(ctx, `SELECT name, colony_id, owner_id, temp_min::float8, temp_max::float8, humidity_min::float8, humidity_max::float8
		FROM sensors WHERE id = $1`, sensor).Scan(&name, &colony, &owner, &tMin, &tMax, &hMin, &hMax)
	if err != nil || colony == nil {
		return err
	}
	lang := s.userLang(ctx, owner) // the timeline entry in the owner's language
	latest := map[string]SensorReading{}
	for _, r := range readings {
		if l, ok := latest[r.Metric]; !ok || r.MeasuredAt.After(l.MeasuredAt) {
			latest[r.Metric] = r
		}
	}
	for metric, r := range latest {
		if now.Sub(r.MeasuredAt) > 2*time.Hour {
			continue
		}
		note := limitText(lang, name, metric, r.Value, tMin, tMax, hMin, hMax)
		if note == "" {
			continue
		}
		note += "."
		// Claim the alert slot first: concurrent batches must not both alert.
		tag, err := s.Pool.Exec(ctx, `INSERT INTO sensor_alerts (sensor_id, metric, alerted_at) VALUES ($1, $2, $3)
			ON CONFLICT (sensor_id, metric) DO UPDATE SET alerted_at = excluded.alerted_at
			WHERE sensor_alerts.alerted_at < $3 - make_interval(secs => $4)`, sensor, metric, now, sensorAlertPause.Seconds())
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			continue // alerted recently
		}
		payload, _ := json.Marshal(map[string]any{"source": "sensor", "sensor_id": sensor, "metric": metric, "value": r.Value})
		if _, err := s.Pool.Exec(ctx, `INSERT INTO colony_events (id, colony_id, type, occurred_at, note, severity, payload)
			VALUES ($1, $2, 'problem', $3, $4, 'warning', $5)`, uuid.Must(uuid.NewV7()), *colony, r.MeasuredAt, note, payload); err != nil {
			return err
		}
	}
	return nil
}

// num formats like the app: one decimal, comma as separator.
func num(v float64) string { return numIn("de", v) }

// numIn: one decimal – comma in German, point in English.
func numIn(lang string, v float64) string {
	s := strconv.FormatFloat(v, 'f', 1, 64)
	if lang == "de" {
		s = strings.Replace(s, ".", ",", 1)
	}
	return s
}
