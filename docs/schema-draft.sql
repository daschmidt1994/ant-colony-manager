-- =============================================================================
-- Ant Colony Manager – PostgreSQL-Schema (Entwurf Phase 1)
-- Zielversion: PostgreSQL 18 (nutzt uuidv7(), NULLS NOT DISTINCT)
-- Wird in Phase 3 in goose-Migrationen aufgeteilt.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;

-- -----------------------------------------------------------------------------
-- Sync-Infrastruktur
-- -----------------------------------------------------------------------------

-- Globaler, streng monotoner Änderungszähler. Die Zeilensperre serialisiert
-- schreibende Transaktionen → Reihenfolge der seq == Commit-Reihenfolge.
-- Dadurch kann ein Pull-Cursor (seq > x) niemals Änderungen überspringen.
-- Für eine Self-Hosted-Instanz (wenige gleichzeitige Schreiber) unkritisch.
CREATE TABLE sync_counter (
    id    boolean PRIMARY KEY DEFAULT true CHECK (id),
    value bigint  NOT NULL DEFAULT 0
);
INSERT INTO sync_counter DEFAULT VALUES;

CREATE FUNCTION next_seq() RETURNS bigint LANGUAGE sql AS $$
    UPDATE sync_counter SET value = value + 1 RETURNING value;
$$;

CREATE TABLE change_log (
    seq            bigint      PRIMARY KEY,
    entity         text        NOT NULL,
    entity_id      uuid        NOT NULL,
    colony_id      uuid,                   -- Sichtbarkeit über colony_members
    owner_id       uuid,                   -- Sichtbarkeit für nutzereigene Stammdaten
    op             text        NOT NULL CHECK (op IN ('upsert', 'delete')),
    changed_fields text[],
    changed_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX change_log_colony_seq ON change_log (colony_id, seq) WHERE colony_id IS NOT NULL;
CREATE INDEX change_log_owner_seq  ON change_log (owner_id, seq)  WHERE owner_id IS NOT NULL;

-- BEFORE-Trigger: Version + updated_at setzen
CREATE FUNCTION sync_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.version    := next_seq();
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- AFTER-Trigger: Änderung protokollieren (nur Aggregat-Wurzeln haben diesen Trigger)
CREATE FUNCTION sync_log() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_new    jsonb := to_jsonb(NEW);
    v_old    jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END;
    v_colony uuid;
    v_owner  uuid;
    v_fields text[];
BEGIN
    v_colony := CASE WHEN TG_TABLE_NAME = 'colonies'
                     THEN (v_new->>'id')::uuid
                     ELSE (v_new->>'colony_id')::uuid END;
    -- colony_members: der betroffene Nutzer muss auch seinen Entzug sehen
    v_owner  := COALESCE((v_new->>'owner_id')::uuid,
                         CASE WHEN TG_TABLE_NAME = 'colony_members'
                              THEN (v_new->>'user_id')::uuid END);
    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(k) INTO v_fields
        FROM jsonb_object_keys(v_new) AS k
        WHERE k NOT IN ('version', 'updated_at', 'updated_by')
          AND v_new->k IS DISTINCT FROM v_old->k;
    END IF;
    INSERT INTO change_log (seq, entity, entity_id, colony_id, owner_id, op, changed_fields)
    VALUES ((v_new->>'version')::bigint, TG_TABLE_NAME, (v_new->>'id')::uuid,
            v_colony, v_owner,
            CASE WHEN (v_new->>'deleted_at') IS NOT NULL THEN 'delete' ELSE 'upsert' END,
            v_fields);
    RETURN NULL;
END $$;

-- Idempotenz: jede Client-Operation wird genau einmal angewendet
CREATE TABLE applied_ops (
    op_id      uuid        PRIMARY KEY,           -- vom Client erzeugt
    user_id    uuid        NOT NULL,
    device_id  uuid        NOT NULL,
    entity     text        NOT NULL,
    entity_id  uuid        NOT NULL,
    result     jsonb       NOT NULL,              -- wird bei Wiederholung unverändert zurückgegeben
    applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX applied_ops_applied_at ON applied_ops (applied_at);   -- GC nach 90 Tagen

CREATE TABLE instance_settings (
    key        text PRIMARY KEY,                  -- z. B. 'tombstone_horizon_seq', 'setup_completed'
    value      jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Benutzer & Authentifizierung
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    id                uuid        PRIMARY KEY DEFAULT uuidv7(),
    email             citext      NOT NULL UNIQUE,
    password_hash     text        NOT NULL,       -- argon2id, PHC-String
    display_name      text        NOT NULL CHECK (length(display_name) BETWEEN 1 AND 100),
    instance_role     text        NOT NULL DEFAULT 'user' CHECK (instance_role IN ('admin', 'user')),
    email_verified_at timestamptz,
    disabled_at       timestamptz,
    last_login_at     timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    id           uuid        PRIMARY KEY,         -- vom Client erzeugt
    user_id      uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    name         text        NOT NULL,
    platform     text        NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
    app_version  text,
    last_sync_at timestamptz,
    last_pull_seq bigint,
    created_at   timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz
);
CREATE INDEX devices_user ON devices (user_id);

-- Refresh-Tokens (opak, nur Hash gespeichert), Rotation mit Familien-Erkennung
CREATE TABLE sessions (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    user_id      uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    device_id    uuid        REFERENCES devices ON DELETE CASCADE,
    family_id    uuid        NOT NULL,
    token_hash   bytea       NOT NULL UNIQUE,     -- SHA-256
    expires_at   timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    rotated_at   timestamptz,                     -- gesetzt → erneute Verwendung = Diebstahl → Familie sperren
    revoked_at   timestamptz,
    user_agent   text
);
CREATE INDEX sessions_user   ON sessions (user_id);
CREATE INDEX sessions_family ON sessions (family_id);

CREATE TABLE password_resets (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    user_id    uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    token_hash bytea       NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE invitations (
    id          uuid        PRIMARY KEY DEFAULT uuidv7(),
    created_by  uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    email       citext,
    token_hash  bytea       NOT NULL UNIQUE,
    -- optional: Einladung gleichzeitig als Freigabe einer Kolonie
    colony_id   uuid,
    colony_role text        CHECK (colony_role IN ('editor', 'viewer')),
    expires_at  timestamptz NOT NULL,
    accepted_at timestamptz,
    accepted_by uuid        REFERENCES users ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_settings (
    id                   uuid        PRIMARY KEY REFERENCES users ON DELETE CASCADE, -- = user_id
    owner_id             uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    timezone             text        NOT NULL DEFAULT 'Europe/Berlin',
    locale               text        NOT NULL DEFAULT 'de',
    theme                text        NOT NULL DEFAULT 'system' CHECK (theme IN ('system', 'light', 'dark')),
    due_soon_days        int         NOT NULL DEFAULT 1 CHECK (due_soon_days BETWEEN 0 AND 14),
    digest_time          time        NOT NULL DEFAULT '18:00',
    notify_overdue       boolean     NOT NULL DEFAULT true,
    email_digest         boolean     NOT NULL DEFAULT false,
    label_defaults       jsonb       NOT NULL DEFAULT '{}',
    version              bigint      NOT NULL DEFAULT 0,
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (id = owner_id)
);

-- -----------------------------------------------------------------------------
-- Stammdaten
-- -----------------------------------------------------------------------------

CREATE TABLE species (
    id              uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id        uuid        REFERENCES users ON DELETE CASCADE,   -- NULL = Systemkatalog
    scientific_name text        NOT NULL,
    genus           text        NOT NULL,
    subfamily       text,
    german_name     text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    version         bigint      NOT NULL DEFAULT 0,
    deleted_at      timestamptz
);
CREATE UNIQUE INDEX species_name_uniq ON species (owner_id, lower(scientific_name)) NULLS NOT DISTINCT
    WHERE deleted_at IS NULL;
CREATE INDEX species_name_trgm ON species USING gin (scientific_name gin_trgm_ops);
CREATE INDEX species_genus     ON species (genus);

CREATE TABLE food_items (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id     uuid        REFERENCES users ON DELETE CASCADE,      -- NULL = Systemkatalog
    name         text        NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    category     text        NOT NULL CHECK (category IN ('protein', 'carbohydrate', 'other')),
    default_unit text        NOT NULL DEFAULT 'piece' CHECK (default_unit IN ('piece', 'drop', 'ml', 'g', 'portion')),
    sort_order   int         NOT NULL DEFAULT 0,
    archived_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    version      bigint      NOT NULL DEFAULT 0,
    deleted_at   timestamptz
);
CREATE UNIQUE INDEX food_items_name_uniq ON food_items (owner_id, lower(name)) NULLS NOT DISTINCT
    WHERE deleted_at IS NULL;

CREATE TABLE locations (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id   uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    parent_id  uuid        REFERENCES locations ON DELETE RESTRICT,
    name       text        NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    path       text        NOT NULL DEFAULT '',   -- serverseitig gepflegt: 'Ameisenraum/Regal A/Ebene 3'
    sort_order int         NOT NULL DEFAULT 0,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version    bigint      NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    CHECK (parent_id IS DISTINCT FROM id)
);
CREATE INDEX locations_owner  ON locations (owner_id);
CREATE INDEX locations_parent ON locations (parent_id);
CREATE INDEX locations_path   ON locations (owner_id, path text_pattern_ops);

-- -----------------------------------------------------------------------------
-- Kolonien & Zugriff
-- -----------------------------------------------------------------------------

CREATE TABLE colonies (
    id                     uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id               uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    number                 int         NOT NULL CHECK (number > 0),   -- „Kolonie #12“
    name                   text        NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    internal_code          text        CHECK (length(internal_code) <= 32),
    species_id             uuid        REFERENCES species ON DELETE SET NULL,
    species_text           text,                                        -- Fallback/Freitext
    origin                 text        CHECK (origin IN ('wild_caught', 'bought', 'bred', 'traded', 'gift', 'other')),
    find_location          text,                                        -- sensibel: nie öffentlich
    found_on               date,
    bought_on              date,
    seller                 text,
    founded_on             date,
    location_id            uuid        REFERENCES locations ON DELETE SET NULL,
    status                 text        NOT NULL DEFAULT 'active' CHECK (status IN
                               ('founding', 'active', 'hibernating', 'paused', 'given_away', 'sold', 'deceased')),
    gyne_type              text        NOT NULL DEFAULT 'unknown' CHECK (gyne_type IN ('monogyne', 'polygyne', 'unknown')),
    notes                  text,
    archived_at            timestamptz,
    -- denormalisiert, serverseitig gepflegt (Dashboard/Liste ohne Joins):
    queen_count            int,
    worker_estimate_min    int,
    worker_estimate_max    int,
    last_measurement       jsonb,     -- {"temperature": 25.4, "humidity": 61, "at": "..."}
    created_by             uuid        REFERENCES users ON DELETE SET NULL,
    updated_by             uuid        REFERENCES users ON DELETE SET NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    version                bigint      NOT NULL DEFAULT 0,
    deleted_at             timestamptz,
    CHECK (species_id IS NOT NULL OR species_text IS NOT NULL)
);
CREATE UNIQUE INDEX colonies_number_uniq ON colonies (owner_id, number) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX colonies_code_uniq   ON colonies (owner_id, lower(internal_code))
    WHERE deleted_at IS NULL AND internal_code IS NOT NULL;
CREATE INDEX colonies_owner_status ON colonies (owner_id, status) WHERE deleted_at IS NULL;
CREATE INDEX colonies_location     ON colonies (location_id);
CREATE INDEX colonies_species      ON colonies (species_id);
CREATE INDEX colonies_name_trgm    ON colonies USING gin (name gin_trgm_ops);

CREATE TABLE colony_members (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    colony_id  uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    user_id    uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    role       text        NOT NULL CHECK (role IN ('owner', 'editor', 'viewer')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version    bigint      NOT NULL DEFAULT 0,
    deleted_at timestamptz
);
CREATE UNIQUE INDEX colony_members_uniq  ON colony_members (colony_id, user_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX colony_members_owner ON colony_members (colony_id) WHERE role = 'owner' AND deleted_at IS NULL;
CREATE INDEX colony_members_user ON colony_members (user_id, colony_id) WHERE deleted_at IS NULL;

CREATE TABLE queens (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    colony_id  uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    label      text,                               -- „Königin A“, Markierung …
    status     text        NOT NULL DEFAULT 'alive' CHECK (status IN ('alive', 'dead', 'removed', 'unknown')),
    added_on   date,
    ended_on   date,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version    bigint      NOT NULL DEFAULT 0,
    deleted_at timestamptz
);
CREATE INDEX queens_colony ON queens (colony_id);

CREATE TABLE habitats (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id     uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    colony_id    uuid        REFERENCES colonies ON DELETE SET NULL,   -- aktuell in Benutzung durch
    name         text        NOT NULL,
    role         text        NOT NULL DEFAULT 'nest' CHECK (role IN ('nest', 'arena', 'combined')),
    habitat_type text        NOT NULL DEFAULT 'other' CHECK (habitat_type IN
                     ('test_tube', 'ytong', 'plaster', 'acrylic', 'glass', 'soil', '3d_print', 'natural', 'other')),
    manufacturer text,
    model        text,
    material     text,
    size_text    text,
    acquired_on  date,
    status       text        NOT NULL DEFAULT 'in_use' CHECK (status IN ('in_use', 'stored', 'retired')),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    version      bigint      NOT NULL DEFAULT 0,
    deleted_at   timestamptz
);
CREATE INDEX habitats_owner  ON habitats (owner_id);
CREATE INDEX habitats_colony ON habitats (colony_id);

CREATE TABLE winter_rests (
    id              uuid        PRIMARY KEY DEFAULT uuidv7(),
    colony_id       uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    started_on      date        NOT NULL,
    planned_end_on  date,
    ended_on        date,
    target_temp_c   numeric(4,1),
    location_id     uuid        REFERENCES locations ON DELETE SET NULL,
    reminder_mode   text        NOT NULL DEFAULT 'scale' CHECK (reminder_mode IN ('pause', 'scale', 'keep')),
    reminder_factor numeric(4,1) NOT NULL DEFAULT 4 CHECK (reminder_factor >= 1),
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    version         bigint      NOT NULL DEFAULT 0,
    deleted_at      timestamptz,
    CHECK (ended_on IS NULL OR ended_on >= started_on)
);
-- höchstens eine laufende Winterruhe pro Kolonie
CREATE UNIQUE INDEX winter_rests_open ON winter_rests (colony_id) WHERE ended_on IS NULL AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- Planung
-- -----------------------------------------------------------------------------

CREATE TABLE care_schedules (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    colony_id     uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    task_type     text        NOT NULL CHECK (task_type IN
                      ('protein', 'carbohydrate', 'feeding', 'water', 'cleaning', 'check', 'custom')),
    title         text,                             -- Pflicht bei custom
    interval_days numeric(5,1) NOT NULL CHECK (interval_days > 0),
    starts_at     timestamptz NOT NULL DEFAULT now(),
    active        boolean     NOT NULL DEFAULT true,
    winter_mode   text        CHECK (winter_mode IN ('pause', 'scale', 'keep')),  -- NULL = Einstellung der Winterruhe
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    version       bigint      NOT NULL DEFAULT 0,
    deleted_at    timestamptz,
    CHECK (task_type <> 'custom' OR title IS NOT NULL)
);
CREATE UNIQUE INDEX care_schedules_uniq ON care_schedules (colony_id, task_type)
    WHERE task_type <> 'custom' AND deleted_at IS NULL;

CREATE TABLE tasks (
    id             uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id       uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    colony_id      uuid        REFERENCES colonies ON DELETE CASCADE,   -- NULL = allgemeine Aufgabe
    title          text        NOT NULL,
    notes          text,
    due_at         timestamptz,
    done_at        timestamptz,
    done_event_id  uuid,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    version        bigint      NOT NULL DEFAULT 0,
    deleted_at     timestamptz
);
CREATE INDEX tasks_open ON tasks (owner_id, due_at) WHERE done_at IS NULL AND deleted_at IS NULL;

CREATE TABLE care_rounds (
    id          uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id    uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    started_at  timestamptz NOT NULL,
    ended_at    timestamptz,
    location_id uuid        REFERENCES locations ON DELETE SET NULL,   -- Filter „nur Regal A“
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    version     bigint      NOT NULL DEFAULT 0,
    deleted_at  timestamptz
);

CREATE TABLE care_round_colonies (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    care_round_id uuid        NOT NULL REFERENCES care_rounds ON DELETE CASCADE,
    colony_id     uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    planned       boolean     NOT NULL DEFAULT true,
    visited_at    timestamptz,
    skipped       boolean     NOT NULL DEFAULT false,
    UNIQUE (care_round_id, colony_id)
);

-- -----------------------------------------------------------------------------
-- Events (Timeline) – Basistabelle + Details
-- Details werden ausschließlich über den Event-Service geschrieben, der immer
-- auch die Zeile in colony_events aktualisiert → ein change_log-Eintrag pro Aggregat.
-- -----------------------------------------------------------------------------

CREATE TABLE colony_events (
    id             uuid        PRIMARY KEY,         -- immer vom Client erzeugt (UUIDv7)
    colony_id      uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    type           text        NOT NULL CHECK (type IN (
                       'feeding', 'water', 'cleaning', 'check', 'note', 'problem', 'photo',
                       'measurement', 'census', 'brood', 'habitat_move', 'queen',
                       'winter_start', 'winter_end', 'status_change', 'custom_task')),
    occurred_at    timestamptz NOT NULL,
    note           text        CHECK (length(note) <= 10000),
    severity       text        CHECK (severity IN ('info', 'warning', 'critical')),  -- für 'problem'
    schedule_id    uuid        REFERENCES care_schedules ON DELETE SET NULL,      -- custom-Aufgabe erledigt
    care_round_id  uuid        REFERENCES care_rounds ON DELETE SET NULL,
    winter_rest_id uuid        REFERENCES winter_rests ON DELETE SET NULL,
    payload        jsonb,                           -- z. B. status_change {from,to}; kleine Zusatzdaten
    created_by     uuid        REFERENCES users ON DELETE SET NULL,
    updated_by     uuid        REFERENCES users ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    version        bigint      NOT NULL DEFAULT 0,
    deleted_at     timestamptz
);
CREATE INDEX colony_events_timeline ON colony_events (colony_id, occurred_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX colony_events_type     ON colony_events (colony_id, type, occurred_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX colony_events_round    ON colony_events (care_round_id) WHERE care_round_id IS NOT NULL;

CREATE TABLE feedings (
    event_id   uuid PRIMARY KEY REFERENCES colony_events ON DELETE CASCADE,
    acceptance text NOT NULL DEFAULT 'unknown' CHECK (acceptance IN ('accepted', 'partial', 'ignored', 'unknown'))
);

CREATE TABLE feeding_items (
    id                uuid          PRIMARY KEY,
    feeding_id        uuid          NOT NULL REFERENCES feedings ON DELETE CASCADE,
    food_item_id      uuid          REFERENCES food_items ON DELETE SET NULL,
    food_name         text          NOT NULL,        -- Snapshot: Statistik bleibt korrekt nach Umbenennung
    category          text          NOT NULL CHECK (category IN ('protein', 'carbohydrate', 'other')),
    quantity          numeric(8,2)  CHECK (quantity > 0),
    unit              text          CHECK (unit IN ('piece', 'drop', 'ml', 'g', 'portion')),
    size              text          CHECK (size IN ('tiny', 'small', 'medium', 'large')),
    acceptance        text          CHECK (acceptance IN ('accepted', 'partial', 'ignored', 'unknown')),
    position          smallint      NOT NULL DEFAULT 0
);
CREATE INDEX feeding_items_feeding ON feeding_items (feeding_id);

CREATE TABLE waterings (
    event_id uuid   PRIMARY KEY REFERENCES colony_events ON DELETE CASCADE,
    kinds    text[] NOT NULL CHECK (cardinality(kinds) > 0 AND kinds <@ ARRAY[
                 'drinker_refilled', 'nest_moistened', 'tank_refilled', 'water_changed']::text[])
);

CREATE TABLE cleanings (
    event_id uuid   PRIMARY KEY REFERENCES colony_events ON DELETE CASCADE,
    kinds    text[] NOT NULL CHECK (cardinality(kinds) > 0 AND kinds <@ ARRAY[
                 'arena', 'food_remains', 'midden', 'glass', 'drinker', 'nest', 'nest_changed', 'other']::text[])
);

CREATE TABLE measurements (
    id       uuid         PRIMARY KEY,
    event_id uuid         NOT NULL REFERENCES colony_events ON DELETE CASCADE,
    metric   text         NOT NULL CHECK (metric IN ('temperature', 'humidity')),
    value    numeric(6,2) NOT NULL,
    unit     text         NOT NULL CHECK (unit IN ('celsius', 'percent')),
    place    text         CHECK (place IN ('nest', 'arena', 'room', 'other')),
    CHECK ((metric = 'temperature' AND unit = 'celsius' AND value BETWEEN -30 AND 60)
        OR (metric = 'humidity'    AND unit = 'percent' AND value BETWEEN 0 AND 100))
);
CREATE INDEX measurements_event ON measurements (event_id);

CREATE TABLE colony_counts (
    event_id     uuid PRIMARY KEY REFERENCES colony_events ON DELETE CASCADE,
    exact_count  int  CHECK (exact_count >= 0),
    estimate_min int  CHECK (estimate_min >= 0),
    estimate_max int,                               -- NULL bei offenem Bereich „10.000+“
    CHECK (exact_count IS NOT NULL OR estimate_min IS NOT NULL),
    CHECK (estimate_max IS NULL OR estimate_max >= estimate_min)
);

CREATE TABLE brood_counts (
    id          uuid PRIMARY KEY,
    event_id    uuid NOT NULL REFERENCES colony_events ON DELETE CASCADE,
    stage       text NOT NULL CHECK (stage IN ('eggs', 'larvae', 'pupae', 'naked_pupae', 'alates')),
    exact_count int  CHECK (exact_count >= 0),
    level       text CHECK (level IN ('none', 'few', 'medium', 'many')),
    CHECK (exact_count IS NOT NULL OR level IS NOT NULL),
    UNIQUE (event_id, stage)
);

CREATE TABLE habitat_moves (
    event_id        uuid PRIMARY KEY REFERENCES colony_events ON DELETE CASCADE,
    from_habitat_id uuid REFERENCES habitats ON DELETE SET NULL,
    to_habitat_id   uuid REFERENCES habitats ON DELETE SET NULL,
    reason          text
);

CREATE TABLE queen_events (
    event_id uuid PRIMARY KEY REFERENCES colony_events ON DELETE CASCADE,
    queen_id uuid REFERENCES queens ON DELETE SET NULL,
    action   text NOT NULL CHECK (action IN ('added', 'died', 'removed', 'observed'))
);

-- -----------------------------------------------------------------------------
-- Fotos
-- -----------------------------------------------------------------------------

CREATE TABLE photos (
    id           uuid        PRIMARY KEY,           -- vom Client erzeugt
    owner_id     uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    colony_id    uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    event_id     uuid        REFERENCES colony_events ON DELETE SET NULL,
    queen_id     uuid        REFERENCES queens ON DELETE SET NULL,
    habitat_id   uuid        REFERENCES habitats ON DELETE SET NULL,
    upload_state text        NOT NULL DEFAULT 'pending' CHECK (upload_state IN ('pending', 'stored', 'failed')),
    sha256       bytea       CHECK (octet_length(sha256) = 32),
    storage_key  text,                              -- content-adressiert: 'ab/cd/<sha256>.jpg'
    thumb_key    text,
    original_key text,                              -- optional (Einstellung „Original behalten“)
    mime         text        CHECK (mime IN ('image/jpeg', 'image/webp', 'image/png')),
    bytes        int         CHECK (bytes > 0),
    width        int,
    height       int,
    taken_at     timestamptz,                       -- aus EXIF, sonst Aufnahmezeit
    caption      text,
    created_by   uuid        REFERENCES users ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    version      bigint      NOT NULL DEFAULT 0,
    deleted_at   timestamptz
);
CREATE INDEX photos_colony ON photos (colony_id, taken_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX photos_event  ON photos (event_id) WHERE event_id IS NOT NULL;
CREATE INDEX photos_sha    ON photos (sha256);

-- -----------------------------------------------------------------------------
-- Scan: QR + NFC
-- -----------------------------------------------------------------------------

CREATE TABLE scan_links (
    id         uuid        PRIMARY KEY,             -- vom Client erzeugt (NFC-Zuweisung offline möglich)
    colony_id  uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    token      text        NOT NULL UNIQUE CHECK (token ~ '^[0-9A-Za-z]{16}$'),
    kind       text        NOT NULL CHECK (kind IN ('qr', 'nfc')),
    label      text,
    active     boolean     NOT NULL DEFAULT true,
    revoked_at timestamptz,
    created_by uuid        REFERENCES users ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version    bigint      NOT NULL DEFAULT 0,
    deleted_at timestamptz
);
CREATE INDEX scan_links_colony ON scan_links (colony_id);
-- höchstens ein aktiver QR-Link pro Kolonie (NFC: beliebig viele Tags)
CREATE UNIQUE INDEX scan_links_one_qr ON scan_links (colony_id) WHERE kind = 'qr' AND active AND deleted_at IS NULL;

CREATE TABLE nfc_tags (
    id           uuid        PRIMARY KEY,
    owner_id     uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    colony_id    uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    scan_link_id uuid        REFERENCES scan_links ON DELETE SET NULL,   -- NULL = nur per UID registriert
    uid_hash     bytea       NOT NULL CHECK (octet_length(uid_hash) = 32),  -- HMAC-SHA256(UID, Instanz-Secret)
    tag_type     text,                              -- 'NTAG213', 'NTAG215', …
    locked       boolean     NOT NULL DEFAULT false,
    label        text,
    written_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    version      bigint      NOT NULL DEFAULT 0,
    deleted_at   timestamptz
);
CREATE UNIQUE INDEX nfc_tags_uid ON nfc_tags (owner_id, uid_hash) WHERE deleted_at IS NULL;
CREATE INDEX nfc_tags_colony ON nfc_tags (colony_id);

-- -----------------------------------------------------------------------------
-- Sensoren (vorbereitet)
-- -----------------------------------------------------------------------------

CREATE TABLE sensors (
    id             uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id       uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    name           text        NOT NULL,
    kind           text        NOT NULL DEFAULT 'generic' CHECK (kind IN ('esp32', 'bluetooth', 'wifi', 'generic')),
    colony_id      uuid        REFERENCES colonies ON DELETE SET NULL,
    habitat_id     uuid        REFERENCES habitats ON DELETE SET NULL,
    location_id    uuid        REFERENCES locations ON DELETE SET NULL,
    api_key_prefix text        NOT NULL UNIQUE,    -- sichtbarer Präfix zur Identifikation
    api_key_hash   bytea       NOT NULL,           -- SHA-256 des Schlüssels
    active         boolean     NOT NULL DEFAULT true,
    last_seen_at   timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    version        bigint      NOT NULL DEFAULT 0,
    deleted_at     timestamptz
);

CREATE TABLE sensor_readings (
    sensor_id   uuid         NOT NULL REFERENCES sensors ON DELETE CASCADE,
    metric      text         NOT NULL CHECK (metric IN ('temperature', 'humidity')),
    measured_at timestamptz  NOT NULL,
    value       numeric(6,2) NOT NULL,
    PRIMARY KEY (sensor_id, metric, measured_at)     -- doppelte Sendungen idempotent
);
CREATE INDEX sensor_readings_time ON sensor_readings USING brin (measured_at);

-- -----------------------------------------------------------------------------
-- Konflikte, Audit, Jobs
-- -----------------------------------------------------------------------------

CREATE TABLE sync_conflicts (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    user_id      uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    entity       text        NOT NULL,
    entity_id    uuid        NOT NULL,
    field        text        NOT NULL,
    lost_value   jsonb,
    kept_value   jsonb,
    lost_device  uuid,
    created_at   timestamptz NOT NULL DEFAULT now(),
    dismissed_at timestamptz
);
CREATE INDEX sync_conflicts_open ON sync_conflicts (user_id) WHERE dismissed_at IS NULL;

CREATE TABLE audit_log (
    id        uuid        PRIMARY KEY DEFAULT uuidv7(),
    user_id   uuid        REFERENCES users ON DELETE SET NULL,
    action    text        NOT NULL,                 -- 'login', 'login_failed', 'colony_shared', 'backup_restored' …
    target    text,
    meta      jsonb,                                -- niemals Passwörter/Tokens
    ip        inet,
    at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_at ON audit_log (at);

CREATE TABLE jobs (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    kind         text        NOT NULL,              -- 'thumbnail', 'email_digest', 'tombstone_gc', 'export'
    payload      jsonb       NOT NULL DEFAULT '{}',
    run_at       timestamptz NOT NULL DEFAULT now(),
    attempts     int         NOT NULL DEFAULT 0,
    locked_until timestamptz,
    last_error   text,
    done_at      timestamptz
);
CREATE INDEX jobs_due ON jobs (run_at) WHERE done_at IS NULL;

-- -----------------------------------------------------------------------------
-- Sync-Trigger an allen Aggregat-Wurzeln
-- -----------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'user_settings', 'species', 'food_items', 'locations', 'colonies', 'colony_members',
        'queens', 'habitats', 'winter_rests', 'care_schedules', 'tasks', 'care_rounds',
        'colony_events', 'photos', 'scan_links', 'nfc_tags', 'sensors']
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION sync_stamp()', t || '_sync_stamp', t);
        EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION sync_log()', t || '_sync_log', t);
    END LOOP;
END $$;
-- care_round_colonies wird als Teil des Aggregats care_rounds synchronisiert (Service fasst care_rounds an).

-- -----------------------------------------------------------------------------
-- Fälligkeiten (Server-Sicht; identische Regeln wie im Dart-DueCalculator)
-- -----------------------------------------------------------------------------

CREATE VIEW care_due AS
SELECT
    s.id          AS schedule_id,
    s.colony_id,
    c.owner_id,
    s.task_type,
    s.title,
    last.last_done_at,
    w.id          AS winter_rest_id,
    COALESCE(s.winter_mode, w.reminder_mode) AS effective_winter_mode,
    CASE
        WHEN w.id IS NOT NULL AND COALESCE(s.winter_mode, w.reminder_mode) = 'pause' THEN NULL
        ELSE COALESCE(last.last_done_at, s.starts_at)
             + make_interval(secs => (s.interval_days
                   * CASE WHEN w.id IS NOT NULL AND COALESCE(s.winter_mode, w.reminder_mode) = 'scale'
                          THEN w.reminder_factor ELSE 1 END
                   * 86400)::double precision)
    END AS next_due_at
FROM care_schedules s
JOIN colonies c ON c.id = s.colony_id
     AND c.deleted_at IS NULL AND c.archived_at IS NULL
     AND c.status IN ('founding', 'active', 'hibernating')
LEFT JOIN winter_rests w ON w.colony_id = s.colony_id AND w.ended_on IS NULL
     AND w.deleted_at IS NULL AND w.started_on <= current_date
LEFT JOIN LATERAL (
    SELECT max(e.occurred_at) AS last_done_at
    FROM colony_events e
    WHERE e.colony_id = s.colony_id AND e.deleted_at IS NULL AND (
          (s.task_type = 'feeding'      AND e.type = 'feeding')
       OR (s.task_type = 'water'        AND e.type = 'water')
       OR (s.task_type = 'cleaning'     AND e.type = 'cleaning')
       OR (s.task_type = 'check'        AND e.type IN ('check', 'feeding', 'water', 'cleaning', 'census', 'brood'))
       OR (s.task_type = 'custom'       AND e.schedule_id = s.id)
       OR (s.task_type IN ('protein', 'carbohydrate') AND e.type = 'feeding' AND EXISTS (
              SELECT 1 FROM feeding_items fi
              WHERE fi.feeding_id = e.id AND fi.category = s.task_type))
    )
) last ON true
WHERE s.active AND s.deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- Systemkatalog Futtermittel (Seed)
-- -----------------------------------------------------------------------------

INSERT INTO food_items (owner_id, name, category, default_unit, sort_order) VALUES
    (NULL, 'Schabe',          'protein',      'piece',   10),
    (NULL, 'Heimchen',        'protein',      'piece',   20),
    (NULL, 'Grille',          'protein',      'piece',   30),
    (NULL, 'Mehlwurm',        'protein',      'piece',   40),
    (NULL, 'Fliege',          'protein',      'piece',   50),
    (NULL, 'Fruchtfliege',    'protein',      'piece',   60),
    (NULL, 'Wachsmotte',      'protein',      'piece',   70),
    (NULL, 'Sonstiges Insekt','protein',      'piece',   80),
    (NULL, 'Zuckerwasser',    'carbohydrate', 'drop',   110),
    (NULL, 'Honig',           'carbohydrate', 'drop',   120),
    (NULL, 'Honigwasser',     'carbohydrate', 'drop',   130),
    (NULL, 'Ahornsirup',      'carbohydrate', 'drop',   140),
    (NULL, 'Jelly',           'carbohydrate', 'portion',150),
    (NULL, 'Frucht',          'carbohydrate', 'portion',160),
    (NULL, 'Sonstiges',       'other',        'portion',900);
