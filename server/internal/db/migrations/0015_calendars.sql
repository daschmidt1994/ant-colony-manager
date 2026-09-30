-- Mehrere Kalender-Abos pro Benutzer (z. B. einer nur für die Winterruhe,
-- einer für die Fütterungen) – jeder mit Namen, eigener Auswahl der Arten
-- und optional nur bestimmten Kolonien (NULL = alle).
ALTER TABLE feed_tokens DROP CONSTRAINT feed_tokens_user_id_key;
CREATE INDEX feed_tokens_user ON feed_tokens (user_id, created_at);
ALTER TABLE feed_tokens
    ADD COLUMN name       text   NOT NULL DEFAULT 'Ameisen' CHECK (length(name) BETWEEN 1 AND 60),
    ADD COLUMN colony_ids uuid[] CHECK (cardinality(colony_ids) BETWEEN 1 AND 500);
