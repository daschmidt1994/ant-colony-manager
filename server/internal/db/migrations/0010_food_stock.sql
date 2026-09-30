-- Futtervorrat: Futtertiere, Zuckerwasser & Co. mit Menge, Nachbestell-Grenze,
-- „geöffnet am“ + Haltbarkeit nach dem Öffnen, Mindesthaltbarkeit – und
-- Futtertier-Zuchten (kind = 'culture') mit Versorgungs-Intervall.
CREATE TABLE food_stocks (
    id                 uuid          PRIMARY KEY DEFAULT uuidv7(),
    owner_id           uuid          NOT NULL REFERENCES users ON DELETE CASCADE,
    food_item_id       uuid          REFERENCES food_items ON DELETE SET NULL,
    name               text          NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    kind               text          NOT NULL DEFAULT 'stock' CHECK (kind IN ('stock', 'culture')),
    quantity           numeric(10,2) CHECK (quantity >= 0),
    unit               text          CHECK (length(unit) <= 20),
    reorder_below      numeric(10,2) CHECK (reorder_below >= 0),
    opened_on          date,
    use_within_days    int           CHECK (use_within_days BETWEEN 1 AND 3650),
    best_before        date,
    care_interval_days int           CHECK (care_interval_days BETWEEN 1 AND 365),
    last_cared_at      timestamptz,
    notes              text,
    archived_at        timestamptz,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    updated_at         timestamptz   NOT NULL DEFAULT now(),
    version            bigint        NOT NULL DEFAULT 0,
    deleted_at         timestamptz
);
CREATE INDEX food_stocks_owner ON food_stocks (owner_id);

CREATE TRIGGER food_stocks_sync_stamp BEFORE INSERT OR UPDATE ON food_stocks
    FOR EACH ROW EXECUTE FUNCTION sync_stamp();
CREATE TRIGGER food_stocks_sync_log AFTER INSERT OR UPDATE ON food_stocks
    FOR EACH ROW EXECUTE FUNCTION sync_log();
