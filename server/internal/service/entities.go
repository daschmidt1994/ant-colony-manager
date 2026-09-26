package service

import (
	"context"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// scope defines how a record's visibility and write access are determined.
type scope int

const (
	// scopeColony: record belongs to a colony (colony_id); access via colony_members.
	scopeColony scope = iota
	// scopeColonyRoot: the colonies table itself.
	scopeColonyRoot
	// scopeOwner: personal master data (owner_id = user).
	scopeOwner
	// scopeSettings: user_settings (id = owner_id = user), update only.
	scopeSettings
)

type refKind int

const (
	refLocation           refKind = iota // locations of the data owner
	refSpecies                           // system catalog or data owner's species
	refHabitat                           // habitats of the data owner
	refCareRound                         // care rounds of the actor
	refColonyEditor                      // colony where the actor is at least editor
	refColonyOwned                       // colony the actor owns
	refSameColonyQueen                   // queen of the same colony
	refSameColonyEvent                   // event of the same colony
	refSameColonySchedule                // schedule of the same colony
	refSameColonyWinter                  // winter rest of the same colony
	refSameColonyScanLink                // scan link of the same colony
)

type ref struct {
	Field string
	Kind  refKind
}

// entity describes a synchronisable table. Only listed Fields can be written by
// clients; server-managed columns (owner_id, version, …) are never accepted.
type entity struct {
	Scope     scope
	Fields    []string // client-writable columns
	Immutable []string // may be set on create but not changed afterwards
	OwnerOnly []string // only the colony owner may change these
	Hidden    []string // never sent to clients
	HexBytea  []string // bytea columns transported as hex strings
	Refs      []ref
	ReadOnly  bool // not writable through ApplyOp
	// Collection is the REST path segment (/api/v1/<collection>).
	Collection string
	// DeleteRole is the minimum colony role for deletion (default editor).
	DeleteRole Role
	// hooks
	beforeWrite func(ctx context.Context, s *Service, q db.Querier, w *write) error
	afterWrite  func(ctx context.Context, s *Service, q db.Querier, w *write) error
}

var entities = map[string]*entity{
	"colonies": {
		Scope:      scopeColonyRoot,
		Collection: "colonies",
		Fields: []string{"number", "name", "internal_code", "species_id", "species_text", "origin",
			"find_location", "found_on", "bought_on", "seller", "founded_on", "location_id",
			"status", "gyne_type", "notes", "archived_at"},
		OwnerOnly:   []string{"archived_at"},
		Refs:        []ref{{"species_id", refSpecies}, {"location_id", refLocation}},
		DeleteRole:  RoleOwner,
		beforeWrite: colonyBeforeWrite,
		afterWrite:  colonyAfterWrite,
	},
	"colony_members": {Scope: scopeColony, ReadOnly: true, Collection: "members"},
	"queens": {
		Scope: scopeColony, Collection: "queens",
		Fields:     []string{"colony_id", "label", "status", "added_on", "ended_on", "notes"},
		Immutable:  []string{"colony_id"},
		afterWrite: refreshStatsAfterWrite,
	},
	"habitats": {
		Scope: scopeOwner, Collection: "habitats",
		Fields: []string{"colony_id", "name", "role", "habitat_type", "manufacturer", "model", "material",
			"size_text", "acquired_on", "status", "notes"},
		Refs: []ref{{"colony_id", refColonyOwned}},
	},
	"winter_rests": {
		Scope: scopeColony, Collection: "winter-rests",
		Fields: []string{"colony_id", "started_on", "planned_end_on", "ended_on", "target_temp_c",
			"location_id", "reminder_mode", "reminder_factor", "notes"},
		Immutable:  []string{"colony_id"},
		Refs:       []ref{{"location_id", refLocation}},
		afterWrite: winterRestAfterWrite,
	},
	"care_schedules": {
		Scope: scopeColony, Collection: "schedules",
		Fields:    []string{"colony_id", "task_type", "title", "interval_days", "starts_at", "active", "winter_mode"},
		Immutable: []string{"colony_id", "task_type"},
	},
	"tasks": {
		Scope: scopeOwner, Collection: "tasks",
		Fields: []string{"colony_id", "title", "notes", "due_at", "done_at", "done_event_id"},
		Refs:   []ref{{"colony_id", refColonyEditor}},
	},
	"care_rounds": {
		Scope: scopeOwner, Collection: "care-rounds",
		Fields: []string{"started_at", "ended_at", "location_id", "notes"},
		Refs:   []ref{{"location_id", refLocation}},
	},
	"care_round_colonies": {
		Scope: scopeOwner, Collection: "care-round-colonies",
		Fields:    []string{"care_round_id", "colony_id", "planned", "visited_at", "skipped"},
		Immutable: []string{"care_round_id", "colony_id"},
		Refs:      []ref{{"care_round_id", refCareRound}, {"colony_id", refColonyEditor}},
	},
	"colony_events": {
		Scope: scopeColony, Collection: "events",
		Fields: []string{"colony_id", "type", "occurred_at", "note", "severity", "schedule_id",
			"care_round_id", "winter_rest_id", "payload"},
		Immutable: []string{"colony_id", "type"},
		Refs: []ref{{"schedule_id", refSameColonySchedule}, {"care_round_id", refCareRound},
			{"winter_rest_id", refSameColonyWinter}},
		beforeWrite: eventBeforeWrite,
		afterWrite:  eventAfterWrite,
	},
	"photos": {
		Scope: scopeColony, Collection: "photos",
		Fields:    []string{"colony_id", "event_id", "queen_id", "habitat_id", "caption", "taken_at"},
		Immutable: []string{"colony_id"},
		Hidden:    []string{"storage_key", "thumb_key", "original_key"},
		HexBytea:  []string{"sha256"},
		Refs: []ref{{"event_id", refSameColonyEvent}, {"queen_id", refSameColonyQueen},
			{"habitat_id", refHabitat}},
	},
	"scan_links": {
		Scope: scopeColony, Collection: "scan-links",
		Fields:      []string{"colony_id", "token", "kind", "label", "active"},
		Immutable:   []string{"colony_id", "token", "kind"},
		beforeWrite: scanLinkBeforeWrite,
	},
	"nfc_tags": {
		Scope: scopeColony, Collection: "nfc-tags",
		Fields:    []string{"colony_id", "scan_link_id", "uid_hash", "tag_type", "locked", "label", "written_at"},
		Immutable: []string{"colony_id"},
		HexBytea:  []string{"uid_hash"},
		Refs:      []ref{{"scan_link_id", refSameColonyScanLink}},
	},
	"locations": {
		Scope: scopeOwner, Collection: "locations",
		Fields: []string{"parent_id", "name", "sort_order", "notes"},
		Refs:   []ref{{"parent_id", refLocation}},
	},
	"food_items": {
		Scope: scopeOwner, Collection: "food-items",
		Fields: []string{"name", "category", "default_unit", "sort_order", "archived_at"},
	},
	"species": {
		Scope: scopeOwner, Collection: "species",
		Fields:      []string{"scientific_name", "genus", "subfamily", "german_name", "notes"},
		beforeWrite: speciesBeforeWrite,
	},
	"user_settings": {
		Scope: scopeSettings, Collection: "settings",
		Fields: []string{"timezone", "locale", "theme", "due_soon_days", "digest_time",
			"notify_overdue", "email_digest", "label_defaults"},
		beforeWrite: settingsBeforeWrite,
	},
	"sensors": {
		Scope: scopeOwner, Collection: "sensors",
		Fields:      []string{"name", "kind", "colony_id", "habitat_id", "location_id", "active"},
		Hidden:      []string{"api_key_hash"},
		Refs:        []ref{{"colony_id", refColonyOwned}, {"habitat_id", refHabitat}, {"location_id", refLocation}},
		beforeWrite: sensorBeforeWrite,
	},
}

// EntityByCollection maps a REST path segment to the table name.
func EntityByCollection(collection string) (string, bool) {
	for name, e := range entities {
		if e.Collection == collection {
			return name, true
		}
	}
	return "", false
}

// SyncedEntities lists all table names included in pull/snapshot.
func SyncedEntities() []string {
	out := make([]string, 0, len(entities))
	for n := range entities {
		out = append(out, n)
	}
	return out
}
