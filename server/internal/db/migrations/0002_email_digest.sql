-- E-Mail-Tagesüberblick: wann er zuletzt pro Benutzer lief (lokales Datum).
-- Eigene Tabelle statt Spalte in user_settings, damit der tägliche Lauf keine
-- Sync-Änderung an allen Geräten auslöst.
CREATE TABLE digest_log (
    user_id  uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
    sent_on  date NOT NULL
);
