# Ant Colony Manager – Phase 1: Planung

> Status: **Entwurf zur Freigabe** · Stand 2026-09-26
> Leitprinzip: **SCAN → INFORMATION → AKTION → FERTIG**

| # | Dokument | Inhalt |
|---|----------|--------|
| 1 | [01-produkt-und-stack.md](01-produkt-und-stack.md) | Kurz-PRD, Technologie-Stack, Begründungen (inkl. Flutter Web vs. Next.js) |
| 2 | [02-systemarchitektur.md](02-systemarchitektur.md) | Gesamtarchitektur, Schichten, Android-/Web-Architektur, Erinnerungen, Realtime |
| 3 | [03-datenmodell.md](03-datenmodell.md) | PostgreSQL-Datenmodell, Konventionen, ER-Diagramm |
|   | [schema-draft.sql](schema-draft.sql) | Lauffähiger DDL-Entwurf (gegen PostgreSQL 18 getestet) |
| 4 | [04-api.md](04-api.md) | REST-API-Struktur (`/api/v1`) |
| 5 | [05-sync.md](05-sync.md) | Offline-/Sync-Konzept |
| 6 | [06-nfc-qr-deeplinks.md](06-nfc-qr-deeplinks.md) | NFC-, QR- und Deep-Link-Konzept, Etiketten |
| 7 | [07-docker.md](07-docker.md) | Docker-Compose-Architektur, Volumes, Healthchecks, Proxy, Updates |
| 8 | [08-auth-sicherheit.md](08-auth-sicherheit.md) | Authentifizierung, Berechtigungen, Sicherheit |
| 9 | [09-backup-restore.md](09-backup-restore.md) | Backup-/Restore-Konzept |
| 10 | [10-projektstruktur.md](10-projektstruktur.md) | Monorepo-/Ordnerstruktur |

## Die wichtigsten Entscheidungen auf einen Blick

1. **Flutter für Android *und* Web** – eine Codebasis, eine Domänenlogik (Fälligkeiten, Timeline, Sync), adaptive Layouts.
2. **Eigenes Go-Backend statt Supabase** – ein statisches Binary (~20 MB Image), läuft auf Raspberry Pi/NAS, liefert zusätzlich die Web-App aus.
3. **Nur 3 Pflicht-Container:** `app` (API + Web), `db` (PostgreSQL 18), `backup`. Optional `proxy` (Caddy). Kein Redis, kein MinIO, keine Microservices.
4. **Offline-first über Outbox + Pull-Cursor**, Client-generierte UUIDv7 und idempotente Operationen → eine Fütterung landet garantiert genau einmal auf dem Server.
5. **Scan-Links mit zufälligen Tokens** (`https://ants.example.com/c/<token>`) statt Kolonie-IDs → QR/NFC können neu generiert und deaktiviert werden und verraten nichts.
6. **Erinnerungen werden lokal auf dem Gerät berechnet und geplant** → keine Abhängigkeit von Firebase/Google-Push, funktioniert offline.
7. **Fotos im Dateisystem-Volume**, content-adressiert → inkrementelle Backups per Hardlinks.

## Entscheidungen (freigegeben 2026-09-26)

- [x] Flutter Web als einzige Web-Oberfläche
- [x] Go als Backend-Sprache
- [x] Standard-APK (NFC + In-App-Scan) + optionaler eigener APK-Build für verifizierte App Links
- [x] Registrierung standardmäßig nur per Einladung
- [x] App-Sprache zunächst Deutsch, i18n vorbereitet (ARB-Dateien)

## Phase 2 – UX/UI

| # | Dokument | Inhalt |
|---|----------|--------|
| 11 | [11-ux-grundlagen.md](11-ux-grundlagen.md) | Designsystem, Farben, Typografie, Navigation, Interaktionsregeln |
| 12 | [12-screens.md](12-screens.md) | alle Screens mit Wireframes (Mobile + Web) |
| 13 | [13-user-flows.md](13-user-flows.md) | User Flows inkl. Tap-Zählung, Fehler- und Offline-Fälle |

## Phase 3 – Datenbank & Backend (umgesetzt)

| Bereich | Stand |
|---|---|
| Schema & Migrationen | `server/internal/db/migrations/0001_init.sql` – automatisch beim Start |
| Backend | Go-Server `server/` (siehe [server/README.md](../server/README.md)) |
| API-Dokumentation | [api/openapi.yaml](../api/openapi.yaml) – Test stellt sicher, dass jede Route dokumentiert ist |
| Tests | `scripts/test-server.sh` – Unit- und Integrationstests gegen echtes PostgreSQL 18 |

Abweichungen vom Plan: siehe Hinweis in [01-produkt-und-stack.md](01-produkt-und-stack.md) (pgx statt sqlc/goose, Go 1.26).

## Phase 4 – Docker & Betrieb (umgesetzt)

| Bereich | Stand |
|---|---|
| Stack | [`compose.yml`](../compose.yml): `init`, `db`, `app`, `backup`, optional `proxy` (Caddy); Dev: [`compose.dev.yml`](../compose.dev.yml) |
| Konfiguration | [`.env.example`](../.env.example), [`.env.production.example`](../.env.production.example); Secrets werden automatisch erzeugt |
| Betrieb | `scripts/init-env.sh`, `backup.sh`, `verify-backup.sh`, `restore.sh`, `update.sh` |
| Proxy-Beispiele | [`deploy/examples/`](../deploy/examples) (Nginx, Traefik, Nginx Proxy Manager, restic) |
| Test | `scripts/test-stack.sh` – End-to-End inkl. Restore und HTTPS; CI in `.github/workflows/` |

## Phase 5 – App (umgesetzt)

| Bereich | Stand |
|---|---|
| Code | [`app/`](../app/README.md) – Flutter 3.44 für Android und Web |
| Screens | Server verbinden, Login, Ersteinrichtung, Registrierung, Passwort-Reset, Dashboard, Kolonieliste, Kolonie-Startseite, Kolonie anlegen/bearbeiten, Fütterung, Wasser, Reinigung, Kontrolle, Notiz, Messung, Timeline, Code-Eingabe, Einstellungen, Sync-Details |
| Offline | lokale SQLite-DB + Outbox; Push → Pull → Snapshot |
| Tests | Unit-, Widget- und Sync-Tests; Vertragstest gegen den echten Server (CI) |
| Build | CI baut Web (WASM, ohne CDN) und APK; das Server-Image enthält die Web-App |

## Phase 6 – QR & NFC (umgesetzt)

| Bereich | Stand |
|---|---|
| NFC | Reader-Modus in der App, `NDEF_DISCOVERED` bei geschlossener App, Zuweisen mit Prüfung, Umhängen nach Bestätigung, Seriennummer-Fallback, optional Schreibschutz |
| QR | Kamera-Scanner (Android), Code-Eingabe (Web), „App verbinden“ per QR, QR neu generieren |
| Deep Links | `/c/<code>` aus NFC, Kamera-App, Browser-Button; verifizierte App Links per Build-Parameter |
| Etiketten | PDF mit gebündelter Schrift; 7 Vorlagen; Startfeld für angebrochene Bögen |
| Signatur | eigener Release-Schlüssel in GitHub-Secrets |

## Phase 7 – Offline-Sync (umgesetzt)

Details und Testabdeckung: [05-sync.md §11](05-sync.md#11-umsetzungsstand-phase-7). Wichtigster Fund: nachgetragene Änderungen konnten nach einer verlorenen Serverantwort verloren gehen – behoben und durch Regressions- und Chaos-Tests abgesichert.

## Phase 8 – Pflege-Rundgang (umgesetzt)

| Bereich | Stand |
|---|---|
| Ablauf | Tab „Rundgang“ und Dashboard-Karte: Auswahl (alle mit Aufgaben · alle aktiven · Standort) → Scan (NFC, Kamera, Link) oder Tipp in der „Offen“-Liste → Kolonie-Karte mit Ampel und Schnellaktionen (✓ = in diesem Rundgang erledigt) → Zusammenfassung |
| Regeln | Scan ohne Aktion zählt als kontrolliert; erneuter Scan fragt nach; Kolonie außerhalb der Auswahl wird ergänzt; Pause jederzeit, „Rundgang fortsetzen (7/14)“; nach 12 h ohne Aktivität automatisch beendet |
| Daten | `care_rounds`, `care_round_colonies`; jede Aktion während des Rundgangs trägt `care_round_id` – komplett offline, die Zusammenfassung ist eine lokale Abfrage und auf allen Geräten gleich |
| Android | Display bleibt während des Rundgangs an; jeder Scan (auch aus dem Scan-Tab oder per Tag bei geschlossener App) führt in den Rundgang |
| Tests | `app/test/care_round_test.dart` (Ablauf, Laufweg-Sortierung, 12-h-Ende, Offline-Sync auf ein zweites Gerät), Widget-Test des Ablaufs, Server-Test `care_round_test.go` (ein Batch offline, fremde Rundgänge gesperrt) |

## Phase 9 – Fotos, Erinnerungen, Statistiken, Sensoren, Berichte, Export (umgesetzt)

| Bereich | Stand |
|---|---|
| Fotos | Kamera (Android) bzw. Dateiauswahl (Web, mehrere), vor dem Upload auf 2048 px / JPEG 82 verkleinert; Vorschaubild lokal → Galerie auch offline; Upload-Warteschlange mit Wiederholung, idempotent (`Content-SHA256`); „Fotos nur im WLAN“; Galerie nach Monaten, Vollbild mit Wischen/Zoom, Beschreibung, Löschen; Fotos in Timeline, Kolonie-Seite und Rundgang |
| Erinnerungen | Android: überfällige Pflege einzeln mit **[Erledigt]** (wiederholt passende Fütterung, letzte Wasser-/Reinigungsarten, hakt Aufgaben ab – auch bei geschlossener App) und **[Kolonie öffnen]**; Tages-Überblick zur gewählten Uhrzeit (inexakter Alarm, übersteht Neustarts); stündliche Prüfung auch offline; Winterruhe-Ende; E-Mail-Tagesüberblick vom Server (SMTP) |
| Statistiken | Kolonie: Fütterungen (Protein/KH), Wasser & Reinigung, Wachstum (Stufenlinie), Temperatur/Feuchte (manuell + Sensor), Brut; Zeiträume 7 T · 30 T · 3 M · 1 J · Gesamt. Sammlung: Kolonien, Arten, Gattungen, Arbeiterinnen, Fütterungen Woche/Monat, überfällig, Winterruhe, Verteilungen nach Art/Gattung/Standort. Alles lokal berechnet (offline) |
| Sensoren | Verwaltung mit einmalig angezeigtem Schlüssel, Grenzwerte, Alarm als „Problem“-Eintrag + Benachrichtigung, stumme Sensoren – siehe [14-sensoren.md](14-sensoren.md) |
| Bericht | Koloniebericht als PDF: Steckbrief, Wachstum, Fütterungen (12 Monate), Klima, Brut, Pflegeplan, Timeline, Fotos |
| Export | `GET /api/v1/export.zip`: `export.json`, CSV-Tabellen (Semikolon, UTF-8 für Excel), alle Fotos; in der Web-App unter „Mehr → Daten“ |
| Tests | App: Foto-Warteschlange inkl. Chaos, Erinnerungen, Statistiken, Bericht (PDF-Vorschau in der CI); Vertragstests gegen den echten Server (Foto-Upload, Sensor); Server: E-Mail-Digest, ZIP-Export, Sensor-Alarm |

## Artenkatalog, Futter-Ratgeber, Export-Link

| Bereich | Stand |
|---|---|
| Artenkatalog | „Kolonien → Buch-Symbol“: Suche nach Art, Gattung oder deutschem Namen, Filter nach Schwierigkeit und „ohne Winterruhe“. 22 Arten mitgeliefert (Migration `0005_species_care.sql`), Taxonomie nach AntCat/AntWiki, Haltungswerte als Richtwerte gekennzeichnet, Quellen pro Art |
| Steckbrief | Herkunft, Größen, Klima Nest/Arena, Winterruhe, Gründung, Kolonie, Futter, Haltung, Rechtliches, Quellen. Katalogarten sind schreibgeschützt; „Als eigene Art kopieren“ oder eigene Art anlegen |
| Kolonien | Artfeld schlägt Katalogarten vor und verknüpft `species_id`; Kolonie-Seite zeigt eine Steckbrief-Zeile (Nestklima, Winterruhe, Schwierigkeit). Freitext-Arten funktionieren weiter |
| Futter-Ratgeber | Protein/Kohlenhydrate, Futterinsekten aus Zucht statt Wildfang, Samen für Körnersammler, keine Süßstoffe – mit Studien (DOI) und verlässlichen Quellen (AntWiki, AntCat, AntWeb, Seifert 2018) |
| Export aus der App | `POST /api/v1/export/link` liefert einen signierten Link (5 min, an die Sitzung gebunden); die App öffnet ihn im Browser, der Download startet ohne Login |
| Timeline | Einträge nach links wischen oder lange drücken → löschen (mit Rückfrage) |

## Anleitungen

- [17-unraid-dockhand.md](17-unraid-dockhand.md) – Installation auf Unraid mit Dockhand/Portainer (fertige Compose-Datei)
- [20-benachrichtigungen.md](20-benachrichtigungen.md) – Benachrichtigungen per ntfy (auch eigener Server) und E-Mail: Themen, Häufigkeit, Ruhezeiten
- [19-testinstanz.md](19-testinstanz.md) – zweite Instanz (`edge`) und Test-App „ACM Test“ zum Ausprobieren vor einem Release
- [18-fdroid.md](18-fdroid.md) – Android-App über ein eigenes F-Droid-Repo installieren und aktualisieren
- [16-anleitung-installieren-testen.md](16-anleitung-installieren-testen.md) – Server starten, APK installieren, App verbinden, mit der Testliste testen
- [15-anleitung-geraete.md](15-anleitung-geraete.md) – Geräte & Sitzungen: Gerät benennen, verlorenes Handy abmelden
- [14-sensoren.md](14-sensoren.md) – Sensoren einrichten (ESP32-Beispiel)

