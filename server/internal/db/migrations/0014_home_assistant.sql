-- Home Assistant: Benutzer, die ihre Kolonien zusätzlich zum Administrator an
-- Home Assistant senden (MQTT), und Sensoren, deren Werte der Server aus
-- Home Assistant liest (Entität je Messgröße).
CREATE TABLE mqtt_members (
    user_id    uuid        PRIMARY KEY REFERENCES users ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE sensors DROP CONSTRAINT sensors_kind_check;
ALTER TABLE sensors ADD CONSTRAINT sensors_kind_check
    CHECK (kind IN ('esp32', 'bluetooth', 'wifi', 'generic', 'home_assistant'));
ALTER TABLE sensors
    ADD COLUMN ha_temperature_entity text CHECK (ha_temperature_entity ~ '^[a-z_]+\.[a-z0-9_]+$'),
    ADD COLUMN ha_humidity_entity    text CHECK (ha_humidity_entity ~ '^[a-z_]+\.[a-z0-9_]+$');
