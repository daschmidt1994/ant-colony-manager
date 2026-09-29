-- Kalender-Abo (iCal) und Status für Home Assistant: ein geheimer, nur lesender
-- Schlüssel pro Benutzer. Kalender-Apps können keine Header senden, deshalb
-- steht er in der Adresse; gespeichert wird nur sein Hash.
CREATE TABLE feed_tokens (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    user_id      uuid        NOT NULL UNIQUE REFERENCES users ON DELETE CASCADE,
    prefix       text        NOT NULL UNIQUE,
    token_hash   bytea       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
);
