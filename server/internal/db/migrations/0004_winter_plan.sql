-- Geplante Winterruhe: eine offene Zeile ohne started_on ist nur ein Plan
-- (Erinnerung „Winterruhe beginnen?“ am planned_start_on). Mit dem Schalter in
-- der App wird started_on gesetzt – erst dann gilt die Kolonie als „hibernating“
-- (alle Abfragen prüfen started_on <= current_date, NULL zählt also nicht).
ALTER TABLE winter_rests
    ALTER COLUMN started_on DROP NOT NULL,
    ADD COLUMN planned_start_on date,
    ADD CONSTRAINT winter_rests_start_or_plan CHECK (started_on IS NOT NULL OR planned_start_on IS NOT NULL),
    ADD CONSTRAINT winter_rests_end_needs_start CHECK (ended_on IS NULL OR started_on IS NOT NULL),
    ADD CONSTRAINT winter_rests_plan_order CHECK (planned_end_on IS NULL OR planned_start_on IS NULL
                                                  OR planned_end_on > planned_start_on);
