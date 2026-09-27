package service

import (
	"archive/zip"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ExportZip writes everything the user can see as one ZIP (spec §38):
// export.json (complete, re-importable format), CSV tables for spreadsheets
// and all photos. Streams – memory use does not grow with the collection.
func (s *Service) ExportZip(ctx context.Context, actor Actor, w io.Writer, withPhotos bool) error {
	ex, err := s.Export(ctx, actor)
	if err != nil {
		return err
	}
	cols, err := memberColonyIDs(ctx, s.Pool, actor.UserID)
	if err != nil {
		return err
	}
	if cols == nil {
		cols = []uuid.UUID{}
	}
	zw := zip.NewWriter(w)
	now := s.Now()

	f, err := zw.CreateHeader(&zip.FileHeader{Name: "export.json", Method: zip.Deflate, Modified: now})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", " ")
	if err := enc.Encode(ex); err != nil {
		return err
	}

	for _, t := range csvTables {
		if err := s.writeCSV(ctx, zw, now, t, cols, actor.UserID); err != nil {
			return fmt.Errorf("export %s: %w", t.file, err)
		}
	}
	if err := writeReadme(zw, now); err != nil {
		return err
	}
	if withPhotos {
		if err := s.writePhotos(ctx, zw, cols); err != nil {
			return err
		}
	}
	return zw.Close()
}

type csvTable struct {
	file   string
	header []string
	sql    string // $1 = colony ids, $2 = user id
}

// Semicolon-separated with UTF-8 BOM: opens correctly in Excel and LibreOffice (German locale).
var csvTables = []csvTable{
	{"csv/kolonien.csv",
		[]string{"id", "nummer", "name", "art", "status", "standort", "gegruendet", "herkunft", "koeniginnen",
			"arbeiterinnen_min", "arbeiterinnen_max", "archiviert", "notizen"},
		`SELECT c.id::text, c.number::text, c.name, COALESCE(sp.scientific_name, c.species_text, ''), c.status,
			COALESCE(l.path, ''), COALESCE(c.founded_on::text, ''), COALESCE(c.origin, ''), COALESCE(c.queen_count::text, ''),
			COALESCE(c.worker_estimate_min::text, ''), COALESCE(c.worker_estimate_max::text, ''),
			CASE WHEN c.archived_at IS NULL THEN '' ELSE 'ja' END, COALESCE(c.notes, '')
		FROM colonies c LEFT JOIN species sp ON sp.id = c.species_id LEFT JOIN locations l ON l.id = c.location_id
		WHERE c.id = ANY($1) AND c.deleted_at IS NULL ORDER BY c.number`},
	{"csv/ereignisse.csv",
		[]string{"id", "zeitpunkt", "kolonie", "typ", "notiz", "schwere", "details"},
		`SELECT e.id::text, to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), c.name, e.type,
			COALESCE(e.note, ''), COALESCE(e.severity, ''),
			COALESCE(array_to_string(w.kinds, ', '), array_to_string(cl.kinds, ', '), '')
		FROM colony_events e JOIN colonies c ON c.id = e.colony_id
		LEFT JOIN waterings w ON w.event_id = e.id LEFT JOIN cleanings cl ON cl.event_id = e.id
		WHERE e.colony_id = ANY($1) AND e.deleted_at IS NULL ORDER BY e.occurred_at, e.id`},
	{"csv/fuetterungen.csv",
		[]string{"ereignis_id", "zeitpunkt", "kolonie", "futter", "kategorie", "menge", "einheit", "groesse", "annahme"},
		`SELECT e.id::text, to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), c.name, i.food_name,
			i.category, COALESCE(i.quantity::text, ''), COALESCE(i.unit, ''), COALESCE(i.size, ''),
			COALESCE(i.acceptance, f.acceptance)
		FROM feeding_items i JOIN feedings f ON f.event_id = i.feeding_id JOIN colony_events e ON e.id = f.event_id
		JOIN colonies c ON c.id = e.colony_id
		WHERE e.colony_id = ANY($1) AND e.deleted_at IS NULL ORDER BY e.occurred_at, i.position`},
	{"csv/messungen.csv",
		[]string{"zeitpunkt", "kolonie", "quelle", "messgroesse", "wert", "einheit"},
		`SELECT to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), c.name, 'manuell', m.metric, m.value::text, m.unit
		FROM measurements m JOIN colony_events e ON e.id = m.event_id JOIN colonies c ON c.id = e.colony_id
		WHERE e.colony_id = ANY($1) AND e.deleted_at IS NULL
		UNION ALL
		SELECT to_char(r.measured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), COALESCE(c.name, ''), 'Sensor ' || s.name,
			r.metric, r.value::text, CASE r.metric WHEN 'temperature' THEN 'celsius' ELSE 'percent' END
		FROM sensor_readings r JOIN sensors s ON s.id = r.sensor_id LEFT JOIN colonies c ON c.id = s.colony_id
		WHERE s.owner_id = $2 AND s.deleted_at IS NULL
		ORDER BY 1`},
	{"csv/pflegeintervalle.csv",
		[]string{"kolonie", "aufgabe", "titel", "intervall_tage", "aktiv", "zuletzt_erledigt", "naechste_faelligkeit"},
		`SELECT c.name, d.task_type, COALESCE(d.title, ''), s.interval_days::text, CASE WHEN s.active THEN 'ja' ELSE 'nein' END,
			COALESCE(to_char(d.last_done_at AT TIME ZONE 'UTC', 'YYYY-MM-DD'), ''),
			COALESCE(to_char(d.next_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD'), '')
		FROM care_due d JOIN care_schedules s ON s.id = d.schedule_id JOIN colonies c ON c.id = d.colony_id
		WHERE d.colony_id = ANY($1) ORDER BY c.number, d.task_type`},
}

func (s *Service) writeCSV(ctx context.Context, zw *zip.Writer, now time.Time, t csvTable, cols []uuid.UUID, user uuid.UUID) error {
	f, err := zw.CreateHeader(&zip.FileHeader{Name: t.file, Method: zip.Deflate, Modified: now})
	if err != nil {
		return err
	}
	if _, err := f.Write([]byte("\xEF\xBB\xBF")); err != nil {
		return err
	}
	cw := csv.NewWriter(f)
	cw.Comma = ';'
	if err := cw.Write(t.header); err != nil {
		return err
	}
	args := []any{cols}
	if strings.Contains(t.sql, "$2") {
		args = append(args, user)
	}
	rows, err := s.Pool.Query(ctx, t.sql, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	rec := make([]string, len(t.header))
	for rows.Next() {
		dst := make([]any, len(rec))
		for i := range rec {
			dst[i] = &rec[i]
		}
		if err := rows.Scan(dst...); err != nil {
			return err
		}
		if err := cw.Write(rec); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	cw.Flush()
	return cw.Error()
}

var unsafeName = regexp.MustCompile(`[^\p{L}\p{N} _.#-]+`)

func (s *Service) writePhotos(ctx context.Context, zw *zip.Writer, cols []uuid.UUID) error {
	rows, err := s.Pool.Query(ctx, `
		SELECT p.id, c.name, c.number, COALESCE(p.taken_at, p.created_at), COALESCE(p.original_key, p.storage_key),
			p.original_key IS NOT NULL
		FROM photos p JOIN colonies c ON c.id = p.colony_id
		WHERE p.colony_id = ANY($1) AND p.deleted_at IS NULL AND p.upload_state = 'stored'
		ORDER BY c.number, p.taken_at`, cols)
	if err != nil {
		return err
	}
	type photo struct {
		id       uuid.UUID
		colony   string
		number   int
		at       time.Time
		key      string
		original bool
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (photo, error) {
		var p photo
		err := r.Scan(&p.id, &p.colony, &p.number, &p.at, &p.key, &p.original)
		return p, err
	})
	if err != nil {
		return err
	}
	for _, p := range list {
		if err := ctx.Err(); err != nil {
			return err
		}
		ext := ".jpg"
		if p.original {
			ext = "" // original as uploaded; format unknown here
		}
		dir := fmt.Sprintf("fotos/%03d %s/", p.number, strings.TrimSpace(unsafeName.ReplaceAllString(p.colony, "_")))
		name := dir + p.at.UTC().Format("2006-01-02_150405") + "_" + p.id.String()[:8] + ext
		src, _, err := s.Blobs.Open(p.key)
		if err != nil {
			s.Log.Warn("export: photo file missing", "photo", p.id, "err", err)
			continue
		}
		// JPEGs are already compressed – store instead of deflate.
		dst, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store, Modified: p.at})
		if err == nil {
			_, err = io.Copy(dst, src)
		}
		src.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func writeReadme(zw *zip.Writer, now time.Time) error {
	f, err := zw.CreateHeader(&zip.FileHeader{Name: "LIESMICH.txt", Method: zip.Deflate, Modified: now})
	if err != nil {
		return err
	}
	_, err = io.WriteString(f, `Ant Colony Manager – Datenexport vom `+now.Format("02.01.2006 15:04")+` UTC

export.json          vollständige Daten (alle Tabellen, Format "ant-colony-manager/v1")
csv/*.csv            Tabellen für Excel/LibreOffice (Semikolon, UTF-8); Zeiten in UTC
fotos/<Kolonie>/     alle hochgeladenen Fotos (Original, falls der Server Originale behält)

Die Daten gehören dir. Ein vollständiges Server-Backup (inkl. aller Benutzer)
erstellt der Administrator mit scripts/backup.sh.
`)
	return err
}
