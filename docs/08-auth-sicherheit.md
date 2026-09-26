# 08 – Authentifizierung & Sicherheit

## 1. Erstinstallation

1. `app` startet ohne Nutzer → erzeugt einmaligen **Setup-Token** und schreibt ihn ins Log:
   `Setup: https://ants.example.com/setup?token=…` (gültig bis zur Admin-Anlage).
2. Browser → Setup-Seite → Admin-Konto anlegen. Ohne Token ist `/api/v1/setup` gesperrt → niemand kann eine frisch gestartete, öffentlich erreichbare Instanz „kapern“.
3. Danach Registrierungsmodus laut `REGISTRATION_MODE` (Standard: nur per Einladung).

## 2. Anmeldung & Tokens

| Element | Umsetzung |
|---|---|
| Passwörter | **argon2id** (m=64 MiB, t=3, p=1; auf Pi getestet ≈ 300 ms), min. 10 Zeichen, Prüfung gegen eine eingebettete Liste häufiger Passwörter (`server/internal/auth/common-passwords.txt`, erweiterbar, kein externer Dienst) |
| Access-Token | JWT (HS256, `JWT_SECRET`), **15 min**, Claims: `sub`, `sid`, `iat`, `exp`. Keine Rollen/Kolonie-Rechte im Token – Rechte werden **immer** live geprüft |
| Refresh-Token | 256 Bit zufällig, opak, nur SHA-256 in `sessions`. Gleitend 90 Tage (App bleibt offline lange nutzbar) |
| Rotation | jeder Refresh erzeugt neues Token; Wiederverwendung eines bereits rotierten Tokens → gesamte Token-Familie gesperrt (Diebstahl-Erkennung) |
| Android | Refresh-Token in `flutter_secure_storage` (Keystore), Access-Token nur im Speicher |
| Web | Refresh-Token als Cookie `HttpOnly; Secure; SameSite=Strict; Path=/api/v1/auth` → kein JS-Zugriff, kein CSRF; Access-Token nur im Speicher |
| Logout | Session widerrufen; „Überall abmelden“ widerruft alle |
| Passwort ändern/zurücksetzen | widerruft alle anderen Sessions |
| Passwort-Reset | Token 256 Bit, 30 min gültig, einmalig; Antwort immer gleich (keine Nutzer-Enumeration). Ohne SMTP: Admin erzeugt Link bzw. `docker compose exec app /acm user reset-password <mail>` |
| App verbinden | Web zeigt QR mit `PUBLIC_APP_URL` + Einmal-Code (2 min, einmalig) → App scannt → Session. Kein Passwort-Tippen auf dem Handy nötig |

**Optional später:** TOTP-2FA, Passkeys (WebAuthn), OIDC (z. B. Authentik/Keycloak/Google) – das Session-Modell ist darauf vorbereitet (`sessions` unabhängig vom Login-Verfahren).

## 3. Berechtigungen

```text
Instanz-Rolle:  admin | user           → nur Instanzverwaltung, KEIN Zugriff auf fremde Kolonien
Kolonie-Rolle:  owner | editor | viewer (colony_members)
```

| Aktion | owner | editor | viewer |
|---|:-:|:-:|:-:|
| Kolonie/Timeline/Fotos lesen | ✔ | ✔ | ✔ |
| Events erfassen (Füttern, Wasser …) | ✔ | ✔ | – |
| eigene Events bearbeiten/löschen | ✔ | ✔ | – |
| fremde Events bearbeiten/löschen | ✔ | – | – |
| Stammdaten, Intervalle, Winterruhe | ✔ | ✔ | – |
| QR/NFC verwalten | ✔ | ✔ | – |
| teilen, löschen, archivieren, übertragen | ✔ | – | – |

- Zentrale Funktion `authz.Can(ctx, user, action, colonyID)`; jede Kolonie-bezogene Query enthält zusätzlich den `colony_members`-Join (zwei unabhängige Schutzschichten).
- Nutzerbezogene Stammdaten (Standorte, Futtermittel, Nester) nur für `owner_id`. Geteilte Kolonien zeigen den Standort als **Text-Snapshot**, nicht den Standortbaum des Besitzers.
- Ressourcen fremder Kolonien → **404** statt 403 (keine Existenz-Bestätigung).
- Automatisierter Test: Für *jeden* Endpunkt wird geprüft, dass ein zweiter Nutzer ohne Mitgliedschaft 404 erhält (tabellengetriebener Test, neue Endpunkte ohne Eintrag lassen den Test fehlschlagen).
- **Scan-Links vergeben keine Rechte** – Teilen läuft ausschließlich über Einladungen/Mitgliedschaften.

## 4. API-Sicherheit

| Thema | Maßnahme |
|---|---|
| Transport | HTTPS über Proxy; `Strict-Transport-Security`, wenn `PUBLIC_APP_URL` https ist. LAN-Betrieb mit http wird unterstützt, aber im Admin-Bereich als Warnung angezeigt |
| Rate Limiting | in-process Token-Bucket: Login 5/min pro IP+E-Mail (danach progressive Verzögerung), Reset 3/h, Scan-Auflösung 60/min, allgemein 300/min pro Nutzer, Sensor-Ingest 60/min pro Sensor |
| Echte Client-IP | nur aus `X-Forwarded-For`, wenn der Absender in `TRUSTED_PROXIES` liegt |
| Eingaben | OpenAPI-Validierung + Service-Validierung; Größenlimits für JSON (1 MB, Sync-Push 5 MB) |
| SQL | ausschließlich parametrisiert (sqlc), kein String-Bau |
| CORS | aus – Web-App und API sind Same-Origin |
| Header | `Content-Security-Policy` (`default-src 'self'`, `wasm-unsafe-eval` für Flutter WASM), `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`, `Permissions-Policy: camera=(self)`, `frame-ancestors 'none'` |
| Sensor-Keys | Format `acm_sk_<prefix>_<secret>`, nur SHA-256 gespeichert, einmalige Anzeige, pro Sensor, nur Schreibrecht für genau diesen Sensor, rotierbar |
| Fehlermeldungen | keine Stacktraces/SQL an Clients; Details nur im Log mit Request-ID |
| Abhängigkeiten | wenige, gepinnt; `govulncheck`, `dart pub outdated`, Trivy-Scan der Images in CI; Renovate/Dependabot |

## 5. Datei-Uploads

1. Größenlimit (`UPLOAD_MAX_MB`), Streaming mit Abbruch beim Überschreiten.
2. Typ per **Magic Bytes** (JPEG/PNG/WebP/HEIC), nicht per Dateiendung/Content-Type.
3. Dekodieren mit Pixel-Limit (Schutz vor Dekompressionsbomben, max. 50 MP) und **neu kodieren** → entfernt Metadaten und eingebettete Fremdinhalte.
4. EXIF: Aufnahmedatum und Ausrichtung übernehmen, **GPS-Daten immer entfernen** (Fundorte seltener Arten sind schützenswert).
5. Speichern unter zufälligem/Hash-Pfad außerhalb des Web-Roots; Auslieferung nur über HMAC-signierte, 5 Minuten gültige URLs mit `Content-Disposition: inline`, `X-Content-Type-Options: nosniff`, festem `Content-Type`.

## 6. Datenschutz

- Keine Telemetrie, keine Tracker, keine externen Fonts/CDNs – alles wird ausgeliefert.
- Keine Firebase-/Google-Abhängigkeit (Benachrichtigungen lokal).
- Fundort und Herkunft sind nur für Mitglieder der Kolonie sichtbar.
- Konto löschen entfernt Nutzer, Kolonien (als Besitzer), Fotos und Sessions endgültig (nach 7 Tagen Karenz, sofort per Admin-CLI).
- Vollständiger Datenexport jederzeit (JSON/CSV/Fotos).
- `audit_log` für sicherheitsrelevante Ereignisse (Login, Fehlversuche, Freigaben, Restore), 180 Tage Aufbewahrung, ohne Geheimnisse.

## 7. Offline-Sicherheit auf dem Gerät

- Lokale DB liegt in der App-Sandbox. Optional (Einstellung) App-Sperre per Gerätebiometrie.
- Beim Abmelden: lokale DB + Foto-Cache werden gelöscht (vorher Warnung, falls noch ungesendete Änderungen existieren).
- Gerät in der Web-App abmelden (Session widerrufen) → beim nächsten Online-Kontakt löscht die App ihre lokalen Daten.
