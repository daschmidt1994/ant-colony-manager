-- Backup außer Haus: der Server lädt jedes neue fertige Backup per WebDAV
-- hoch (Nextcloud, NAS, Storage Box). Einstellungen und Status stehen in
-- instance_settings ('offsite', 'offsite_state'); hier merkt er sich, welche
-- Fotos schon oben sind, damit jede Nacht nur neue Fotos übertragen werden.
CREATE TABLE offsite_files (
    path        text        PRIMARY KEY,
    sha256      text        NOT NULL,
    uploaded_at timestamptz NOT NULL DEFAULT now()
);
