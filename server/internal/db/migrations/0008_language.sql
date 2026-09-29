-- Sprache: 'system' (Gerätesprache) oder ein Sprachcode ('de', 'en').
-- Bisher stand überall 'de', ohne dass jemand gewählt hätte → Gerätesprache.
ALTER TABLE user_settings ALTER COLUMN locale SET DEFAULT 'system';
UPDATE user_settings SET locale = 'system' WHERE locale = 'de';

-- Sprache, die die App des Benutzers zuletzt anzeigte (Accept-Language) –
-- für E-Mails und ntfy, wenn 'system' eingestellt ist.
ALTER TABLE users ADD COLUMN lang_hint text CHECK (lang_hint IN ('de', 'en'));
