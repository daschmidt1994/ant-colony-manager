-- Pflegevertretung: eine Person wird zeitlich begrenzt für ausgewählte
-- Kolonien als Pfleger (editor) freigeschaltet – mit Pflegeanweisungen.
-- Die Mitgliedschaften legt der Server an und entfernt sie wieder
-- (colony_members.cover_id); bestehende Freigaben bleiben unberührt.
CREATE TABLE care_covers (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    owner_id     uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    user_id      uuid        NOT NULL REFERENCES users ON DELETE CASCADE,  -- die Vertretung
    starts_on    date        NOT NULL,
    ends_on      date        NOT NULL,
    instructions text        CHECK (length(instructions) <= 5000),
    created_at   timestamptz NOT NULL DEFAULT now(),
    ended_at     timestamptz,                                              -- vorzeitig beendet
    CHECK (ends_on >= starts_on),
    CHECK (user_id <> owner_id)
);
CREATE INDEX care_covers_owner ON care_covers (owner_id);
CREATE INDEX care_covers_user ON care_covers (user_id);

CREATE TABLE care_cover_colonies (
    cover_id     uuid NOT NULL REFERENCES care_covers ON DELETE CASCADE,
    colony_id    uuid NOT NULL REFERENCES colonies ON DELETE CASCADE,
    instructions text CHECK (length(instructions) <= 2000),
    PRIMARY KEY (cover_id, colony_id)
);

ALTER TABLE colony_members ADD COLUMN cover_id uuid REFERENCES care_covers ON DELETE SET NULL;
