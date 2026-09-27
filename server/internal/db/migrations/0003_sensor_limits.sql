-- Grenzwerte pro Sensor: Überschreitung → automatischer „Problem“-Eintrag in
-- der Timeline der Kolonie (und damit eine Benachrichtigung in der App).
ALTER TABLE sensors
    ADD COLUMN temp_min     numeric(5,2),
    ADD COLUMN temp_max     numeric(5,2),
    ADD COLUMN humidity_min numeric(5,2),
    ADD COLUMN humidity_max numeric(5,2),
    ADD CONSTRAINT sensors_temp_limits     CHECK (temp_min IS NULL OR temp_max IS NULL OR temp_min < temp_max),
    ADD CONSTRAINT sensors_humidity_limits CHECK (humidity_min IS NULL OR humidity_max IS NULL OR humidity_min < humidity_max);

-- Letzter Alarm je Sensor und Messgröße (Drosselung, nicht synchronisiert).
CREATE TABLE sensor_alerts (
    sensor_id  uuid        NOT NULL REFERENCES sensors ON DELETE CASCADE,
    metric     text        NOT NULL,
    alerted_at timestamptz NOT NULL,
    PRIMARY KEY (sensor_id, metric)
);
