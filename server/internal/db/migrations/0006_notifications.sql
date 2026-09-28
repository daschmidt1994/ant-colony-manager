-- Benachrichtigungen per ntfy und E-Mail: pro Thema Kanal und Wiederholung,
-- dazu Ruhezeiten. Eigene Tabelle statt user_settings: wird nicht an die
-- Geräte synchronisiert (das ntfy-Token bleibt auf dem Server).
-- Der Tages-Überblick per E-Mail bleibt user_settings.email_digest.
CREATE TABLE notification_prefs (
    user_id              uuid        PRIMARY KEY REFERENCES users ON DELETE CASCADE,
    ntfy_url             text        CHECK (ntfy_url ~ '^https?://[^/\s]+/\S+$' AND length(ntfy_url) <= 500),
    ntfy_token           text        CHECK (length(ntfy_token) <= 500),
    digest_ntfy          boolean     NOT NULL DEFAULT false,
    overdue_email        boolean     NOT NULL DEFAULT false,
    overdue_ntfy         boolean     NOT NULL DEFAULT false,
    overdue_repeat_hours smallint    NOT NULL DEFAULT 24 CHECK (overdue_repeat_hours IN (0, 6, 12, 24)),
    sensor_email         boolean     NOT NULL DEFAULT false,
    sensor_ntfy          boolean     NOT NULL DEFAULT false,
    sensor_repeat_hours  smallint    NOT NULL DEFAULT 6 CHECK (sensor_repeat_hours IN (0, 1, 6, 12, 24)),
    winter_email         boolean     NOT NULL DEFAULT false,
    winter_ntfy          boolean     NOT NULL DEFAULT false,
    winter_repeat_hours  smallint    NOT NULL DEFAULT 24 CHECK (winter_repeat_hours IN (0, 24)),
    quiet_start          time,
    quiet_end            time,
    quiet_except_sensor  boolean     NOT NULL DEFAULT true,
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CHECK ((quiet_start IS NULL) = (quiet_end IS NULL))
);

-- Was wann gemeldet wurde (Wiederholung / „nur einmal“). Schlüssel je Anlass,
-- z. B. 'overdue:<schedule>:<fällig am>' oder 'sensor:<sensor>:<messgröße>';
-- ist der Anlass vorbei, wird die Zeile gelöscht.
CREATE TABLE notification_log (
    user_id uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    key     text        NOT NULL,
    sent_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, key)
);
