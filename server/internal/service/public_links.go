package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

// Public share link per colony: a read-only page without sign-in, e.g. for a
// keeping report („Haltungsbericht“) in a forum. The owner chooses what it
// shows; never shown are find location, seller, location, the owner's name
// or e-mail. A forum text (BBCode) with photos and link is offered as well.

// PublicLinkOptions: what the page shows.
type PublicLinkOptions struct {
	Photos   bool `json:"photos"`
	Timeline bool `json:"timeline"`
	Notes    bool `json:"notes"` // texts of notes and checks in the timeline
}

// PublicLink as the owner sees it.
type PublicLink struct {
	ID        uuid.UUID         `json:"id"`
	URL       string            `json:"url"`
	ForumURL  string            `json:"forum_url"` // BBCode text
	Options   PublicLinkOptions `json:"options"`
	CreatedAt time.Time         `json:"created_at"`
}

func (s *Service) publicLinkURL(token string) string { return s.publicURL() + "/p/" + token }

func (s *Service) PublicLinks(ctx context.Context, actor Actor, colony uuid.UUID) ([]PublicLink, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleOwner); err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT id, token, options, created_at FROM public_links
		WHERE colony_id = $1 AND revoked_at IS NULL ORDER BY created_at`, colony)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (PublicLink, error) {
		var l PublicLink
		var token string
		var opts []byte
		err := r.Scan(&l.ID, &token, &opts, &l.CreatedAt)
		_ = json.Unmarshal(opts, &l.Options)
		l.URL, l.ForumURL = s.publicLinkURL(token), s.publicLinkURL(token)+"/forum.txt"
		return l, err
	})
	if list == nil {
		list = []PublicLink{}
	}
	return list, err
}

// CreatePublicLink makes the colony visible under a new secret address.
func (s *Service) CreatePublicLink(ctx context.Context, actor Actor, colony uuid.UUID, opts PublicLinkOptions, meta ClientMeta) (*PublicLink, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleOwner); err != nil {
		return nil, err
	}
	var n int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM public_links WHERE colony_id = $1 AND revoked_at IS NULL`, colony).Scan(&n); err != nil {
		return nil, err
	}
	if n >= 5 {
		return nil, Invalid("colony_id", "at most 5 public links per colony")
	}
	token := auth.NewToken(18)
	raw, _ := json.Marshal(opts)
	var l PublicLink
	if err := s.Pool.QueryRow(ctx, `INSERT INTO public_links (colony_id, token, created_by, options) VALUES ($1, $2, $3, $4)
		RETURNING id, created_at`, colony, token, actor.UserID, raw).Scan(&l.ID, &l.CreatedAt); err != nil {
		return nil, err
	}
	l.Options, l.URL, l.ForumURL = opts, s.publicLinkURL(token), s.publicLinkURL(token)+"/forum.txt"
	s.Audit(ctx, &actor.UserID, "public_link_created", colony.String(), nil, meta.IP)
	return &l, nil
}

// UpdatePublicLink changes what the page shows.
func (s *Service) UpdatePublicLink(ctx context.Context, actor Actor, id uuid.UUID, opts PublicLinkOptions) error {
	colony, err := s.publicLinkColony(ctx, id)
	if err != nil {
		return err
	}
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleOwner); err != nil {
		return NotFound("public_link")
	}
	raw, _ := json.Marshal(opts)
	_, err = s.Pool.Exec(ctx, `UPDATE public_links SET options = $2 WHERE id = $1`, id, raw)
	return err
}

// RevokePublicLink ends a link at once.
func (s *Service) RevokePublicLink(ctx context.Context, actor Actor, id uuid.UUID, meta ClientMeta) error {
	colony, err := s.publicLinkColony(ctx, id)
	if err != nil {
		return err
	}
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleOwner); err != nil {
		return NotFound("public_link")
	}
	if _, err := s.Pool.Exec(ctx, `UPDATE public_links SET revoked_at = now() WHERE id = $1`, id); err != nil {
		return err
	}
	s.Audit(ctx, &actor.UserID, "public_link_revoked", colony.String(), nil, meta.IP)
	return nil
}

func (s *Service) publicLinkColony(ctx context.Context, id uuid.UUID) (uuid.UUID, error) {
	var colony uuid.UUID
	err := s.Pool.QueryRow(ctx, `SELECT colony_id FROM public_links WHERE id = $1 AND revoked_at IS NULL`, id).Scan(&colony)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, NotFound("public_link")
	}
	return colony, err
}

// ---------------------------------------------------------------------------
// The public page

// PublicColony is what the page shows.
type PublicColony struct {
	Lang      string
	Name      string
	Number    int
	Species   string
	Status    string
	FoundedOn *time.Time
	Queens    *int
	Workers   string // „ca. 200“, „150–250“, „” if unknown
	WorkersAt *time.Time
	Census    []PublicPoint // growth
	Events    []PublicEvent
	Photos    []PublicPhoto
	Options   PublicLinkOptions
	URL       string
	Generated time.Time
	colonyID  uuid.UUID
}

type PublicPoint struct {
	At    time.Time
	Count int
}

type PublicEvent struct {
	At      time.Time
	Label   string
	Details string
}

type PublicPhoto struct {
	ID      uuid.UUID
	TakenAt time.Time
	Caption string
}

var errPublicNotFound = &Problem{Status: http.StatusNotFound, Code: "public_link.not_found", Title: "not found"}

// PublicColonyByToken loads the page of a link; unknown or revoked links,
// deleted colonies look like a missing page.
func (s *Service) PublicColonyByToken(ctx context.Context, token string) (*PublicColony, error) {
	if len(token) < 16 || len(token) > 64 {
		return nil, errPublicNotFound
	}
	var p PublicColony
	var opts []byte
	var owner uuid.UUID
	var founded *time.Time
	var wmin, wmax *int
	err := s.Pool.QueryRow(ctx, `
		SELECT c.id, c.owner_id, c.name, c.number, COALESCE(sp.scientific_name, c.species_text, ''), c.status,
		       c.founded_on, c.queen_count, c.worker_estimate_min, c.worker_estimate_max, l.options
		FROM public_links l JOIN colonies c ON c.id = l.colony_id AND c.deleted_at IS NULL
		LEFT JOIN species sp ON sp.id = c.species_id
		WHERE l.token = $1 AND l.revoked_at IS NULL`, token).
		Scan(&p.colonyID, &owner, &p.Name, &p.Number, &p.Species, &p.Status, &founded, &p.Queens, &wmin, &wmax, &opts)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errPublicNotFound
	}
	if err != nil {
		return nil, err
	}
	_ = json.Unmarshal(opts, &p.Options)
	p.FoundedOn, p.Lang, p.URL, p.Generated = founded, s.userLang(ctx, owner), s.publicLinkURL(token), s.Now()
	p.Workers = workersText(p.Lang, wmin, wmax)

	// growth: every census
	rows, err := s.Pool.Query(ctx, `SELECT e.occurred_at, COALESCE(cc.exact_count, (cc.estimate_min + COALESCE(cc.estimate_max, cc.estimate_min)) / 2)
		FROM colony_events e JOIN colony_counts cc ON cc.event_id = e.id
		WHERE e.colony_id = $1 AND e.deleted_at IS NULL ORDER BY e.occurred_at`, p.colonyID)
	if err != nil {
		return nil, err
	}
	if p.Census, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (PublicPoint, error) {
		var pt PublicPoint
		var n *int
		err := r.Scan(&pt.At, &n)
		if n != nil {
			pt.Count = *n
		}
		return pt, err
	}); err != nil {
		return nil, err
	}
	if len(p.Census) > 0 {
		at := p.Census[len(p.Census)-1].At
		p.WorkersAt = &at
	}

	if p.Options.Timeline {
		if p.Events, err = s.publicEvents(ctx, p.colonyID, p.Lang, p.Options.Notes); err != nil {
			return nil, err
		}
	}
	if p.Options.Photos {
		rows, err := s.Pool.Query(ctx, `SELECT id, COALESCE(taken_at, created_at), COALESCE(caption, '') FROM photos
			WHERE colony_id = $1 AND deleted_at IS NULL AND upload_state = 'stored'
			ORDER BY COALESCE(taken_at, created_at) DESC LIMIT 24`, p.colonyID)
		if err != nil {
			return nil, err
		}
		if p.Photos, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (PublicPhoto, error) {
			var ph PublicPhoto
			err := r.Scan(&ph.ID, &ph.TakenAt, &ph.Caption)
			if !p.Options.Notes {
				ph.Caption = ""
			}
			return ph, err
		}); err != nil {
			return nil, err
		}
	}
	return &p, nil
}

func workersText(lang string, lo, hi *int) string {
	switch {
	case lo == nil:
		return ""
	case hi == nil:
		return tl(lang, "über %d", *lo)
	case *lo == *hi:
		return fmt.Sprint(*lo)
	}
	return fmt.Sprintf("%d–%d", *lo, *hi)
}

// publicEvents: the latest entries with a short, harmless text.
func (s *Service) publicEvents(ctx context.Context, colony uuid.UUID, lang string, notes bool) ([]PublicEvent, error) {
	rows, err := s.Pool.Query(ctx, `SELECT e.occurred_at, e.type, COALESCE(e.note, ''), event_json(e.id)
		FROM colony_events e WHERE e.colony_id = $1 AND e.deleted_at IS NULL
		  AND e.type NOT IN ('photo', 'problem', 'status_change')
		ORDER BY e.occurred_at DESC LIMIT 40`, colony)
	if err != nil {
		return nil, err
	}
	labels := map[string]string{
		"feeding": "Fütterung", "water": "Wasser", "cleaning": "Reinigung", "check": "Kontrolle", "note": "Notiz",
		"measurement": "Messung", "census": "Koloniegröße", "brood": "Brut", "habitat_move": "Umzug", "queen": "Königin",
		"winter_start": "Winterruhe begonnen", "winter_end": "Winterruhe beendet", "custom_task": "Aufgabe erledigt",
		"care_deferred": "Aufgeschoben",
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (PublicEvent, error) {
		var e PublicEvent
		var typ, note string
		var raw []byte
		if err := r.Scan(&e.At, &typ, &note, &raw); err != nil {
			return e, err
		}
		e.Label = tl(lang, labels[typ])
		if e.Label == "" {
			e.Label = typ
		}
		var d struct {
			Feeding *struct {
				Items []struct {
					FoodName string `json:"food_name"`
				} `json:"items"`
			} `json:"feeding"`
			Census *struct {
				Exact *int `json:"exact_count"`
				Min   *int `json:"estimate_min"`
				Max   *int `json:"estimate_max"`
			} `json:"census"`
			Measurements []struct {
				Metric string  `json:"metric"`
				Value  float64 `json:"value"`
			} `json:"measurements"`
		}
		_ = json.Unmarshal(raw, &d)
		var parts []string
		if d.Feeding != nil {
			for _, it := range d.Feeding.Items {
				parts = append(parts, it.FoodName)
			}
		}
		if c := d.Census; c != nil {
			if c.Exact != nil {
				parts = append(parts, fmt.Sprint(*c.Exact))
			} else {
				parts = append(parts, workersText(lang, c.Min, c.Max))
			}
		}
		for _, m := range d.Measurements {
			if m.Metric == "temperature" {
				parts = append(parts, fmt.Sprintf("%.1f °C", m.Value))
			} else {
				parts = append(parts, fmt.Sprintf("%.0f %%", m.Value))
			}
		}
		if notes && note != "" {
			parts = append(parts, note)
		}
		e.Details = strings.Join(parts, " · ")
		return e, nil
	})
}

// PublicPhoto opens a photo of a public page (thumb or display version).
func (s *Service) PublicPhotoFile(ctx context.Context, token string, photo uuid.UUID, thumb bool) (io.ReadSeekCloser, time.Time, error) {
	var key *string
	var at time.Time
	var opts []byte
	err := s.Pool.QueryRow(ctx, `SELECT CASE WHEN $3 THEN p.thumb_key ELSE p.storage_key END, p.updated_at, l.options
		FROM public_links l JOIN colonies c ON c.id = l.colony_id AND c.deleted_at IS NULL
		JOIN photos p ON p.colony_id = c.id AND p.id = $2 AND p.deleted_at IS NULL AND p.upload_state = 'stored'
		WHERE l.token = $1 AND l.revoked_at IS NULL`, token, photo, thumb).Scan(&key, &at, &opts)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && key == nil) {
		return nil, at, errPublicNotFound
	}
	if err != nil {
		return nil, at, err
	}
	var o PublicLinkOptions
	_ = json.Unmarshal(opts, &o)
	if !o.Photos {
		return nil, at, errPublicNotFound
	}
	f, _, err := s.Blobs.Open(*key)
	return f, at, err
}
