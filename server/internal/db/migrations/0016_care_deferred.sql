-- Aufgeschobene Pflege mit Grund („Noch ausreichend Wasser“, „Futter nicht
-- angenommen“): ein Ereignis care_deferred mit schedule_id, payload
-- {reason, days, task_type} und optional note; die Fälligkeit verschiebt
-- care_schedules.snoozed_until.
ALTER TABLE colony_events DROP CONSTRAINT colony_events_type_check;
ALTER TABLE colony_events ADD CONSTRAINT colony_events_type_check CHECK (type IN (
    'feeding', 'water', 'cleaning', 'check', 'note', 'problem', 'photo',
    'measurement', 'census', 'brood', 'habitat_move', 'queen',
    'winter_start', 'winter_end', 'status_change', 'custom_task', 'care_deferred'));
