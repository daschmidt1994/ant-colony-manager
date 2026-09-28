-- „Morgen erinnern“: eine Pflege-Aufgabe gilt bis snoozed_until als nicht
-- fällig (nächste Fälligkeit = später von berechnetem Termin und snoozed_until).
ALTER TABLE care_schedules ADD COLUMN snoozed_until timestamptz;

-- App-Benachrichtigungen (Android) pro Thema; notify_overdue gibt es schon.
-- In user_settings, weil die App sie offline auswertet.
ALTER TABLE user_settings
    ADD COLUMN notify_digest_app boolean NOT NULL DEFAULT true,
    ADD COLUMN notify_sensor_app boolean NOT NULL DEFAULT true,
    ADD COLUMN notify_winter_app boolean NOT NULL DEFAULT true;

CREATE OR REPLACE VIEW care_due AS
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
        ELSE GREATEST(
             COALESCE(last.last_done_at, s.starts_at)
             + make_interval(secs => (s.interval_days
                   * CASE WHEN w.id IS NOT NULL AND COALESCE(s.winter_mode, w.reminder_mode) = 'scale'
                          THEN w.reminder_factor ELSE 1 END
                   * 86400)::double precision),
             s.snoozed_until)   -- GREATEST ignores NULL
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
