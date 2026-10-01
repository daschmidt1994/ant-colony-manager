-- Anmeldung per OIDC/SSO (Authentik, Keycloak, Authelia, Google …): ein Konto
-- kann mit einer Identität (Issuer + Subject) verknüpft sein. Nach der
-- Anmeldung beim Anbieter tauscht die App einen Einmal-Code (2 Minuten)
-- gegen eine Sitzung – wie bei der Geräte-Verknüpfung.
CREATE TABLE user_identities (
    issuer     text        NOT NULL,
    subject    text        NOT NULL,
    user_id    uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (issuer, subject)
);
CREATE INDEX user_identities_user ON user_identities (user_id);

CREATE TABLE sso_codes (
    code_hash  bytea       PRIMARY KEY,
    user_id    uuid        NOT NULL REFERENCES users ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);

-- Öffentlicher Share-Link je Kolonie: eine schreibgeschützte Seite ohne
-- Anmeldung, etwa für Haltungsberichte in Foren. Was sie zeigt, wählt der
-- Besitzer (options); widerrufen = revoked_at.
CREATE TABLE public_links (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    colony_id  uuid        NOT NULL REFERENCES colonies ON DELETE CASCADE,
    token      text        NOT NULL UNIQUE,
    created_by uuid        REFERENCES users ON DELETE SET NULL,
    options    jsonb       NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);
CREATE INDEX public_links_colony ON public_links (colony_id);
