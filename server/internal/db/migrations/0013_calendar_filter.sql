-- Kalender-Abo: was der Kalender zeigt (NULL = alles). Werte: die Pflege-Arten
-- (protein, carbohydrate, feeding, water, cleaning, check, custom), winter
-- (Beginn/Ende der Winterruhe) und tasks (einmalige Aufgaben).
ALTER TABLE feed_tokens ADD COLUMN calendar_types text[];
