# 🐜 Ant Colony Manager

Selbst gehostete Verwaltung von Ameisenkolonien – gebaut für den echten Pflegealltag.
**Homepage:** https://daschmidt1994.github.io/ant-colony-manager/

> **SCAN → INFORMATION → AKTION → FERTIG**
> Handy an den NFC-Tag halten oder QR-Code scannen → die Kolonie ist offen, du siehst, was ansteht, und dokumentierst Fütterung, Wasser oder Reinigung mit einem Tap.

## Funktionen

**Pflege**
- **NFC-Tags und QR-Etiketten** pro Kolonie, **Pflege-Rundgang** für viele Kolonien nacheinander
- **Fälligkeiten mit Ampel**, „Morgen“ oder **Aufschieben mit Grund** („Noch ausreichend Wasser“) – [docs/27](docs/27-vertretung-aufschieben.md)
- **Pflegevertretung** – Kolonien für den Urlaub zeitlich begrenzt mit Anweisungen abgeben, oder ein **Pflegezettel zum Ausdrucken** für Helfer ohne Konto – [docs/27](docs/27-vertretung-aufschieben.md)
- **Eigene Tätigkeiten** mit eigenem Intervall, z. B. **Nest befeuchten** alle 7 Tage – [docs/29](docs/29-eigene-taetigkeiten.md)
- **Timeline, Fotos** (Wachstumsvergleich, Zeitraffer), **Statistik**, Koloniebericht als PDF, Winterruhe
- **Ameisen mit KI zählen** – Claude, ChatGPT oder OpenRouter, auch über mehrere Fotos addiert – [docs/26](docs/26-ki-zaehlung.md)
- **Artenkatalog** mit Steckbriefen (Deutsch/Englisch), EU-Verbotsliste, Schwarmflug-Kalender – [docs/24](docs/24-artenkatalog.md)
- **Futtervorrat** mit Haltbarkeit und Nachbestell-Hinweis – [docs/23](docs/23-futtervorrat.md)
- **Öffentlich teilen** – schreibgeschützte Seite pro Kolonie ohne Anmeldung, mit fertigem Forenbeitrag (BBCode) für Haltungsberichte – [docs/28](docs/28-sso-share.md)

**Benachrichtigungen und Anbindungen**
- **App, ntfy oder E-Mail** – Tages-Überblick, überfällige Pflege, Sensor-Alarm, Winterruhe – [docs/20](docs/20-benachrichtigungen.md)
- **Home Assistant** per MQTT – jede Kolonie als Gerät, mit Knöpfen „erledigt“ und Winterruhe-Schalter – [docs/22](docs/22-kalender-home-assistant.md)
- **Kalender-Abo** – mehrere Kalender, Auswahl nach Art und Kolonie – [docs/22](docs/22-kalender-home-assistant.md)
- **Sensoren** (ESP32 & Co. oder aus Home Assistant) mit Grenzwerten – [docs/14](docs/14-sensoren.md)
- **Widget** für den Android-Startbildschirm

**Betrieb**
- **Android-App** (offline-fähig) und **Web-App** mit denselben Daten, Deutsch und Englisch
- **Anmeldung mit SSO** (OpenID Connect: Authentik, Keycloak, Authelia, Google …) neben Passwort – [docs/28](docs/28-sso-share.md)
- **Selbst gehostet** mit einem `docker compose` – keine Cloud, keine Telemetrie (nur eine abschaltbare Update-Prüfung gegen GitHub, `UPDATE_CHECK=false`)
- **Deine Daten:** Export (JSON, CSV, Fotos), nächtliche Backups als normale Dateien, auf Wunsch **außer Haus** per WebDAV, SMB oder NFS, optional verschlüsselt – [docs/25](docs/25-backup-ausser-haus.md)

## Screenshots

| Übersicht | Kolonie | Statistik | Timeline |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/dashboard.png" width="200" alt="Übersicht mit Fälligkeiten nach Dringlichkeit"> | <img src="docs/screenshots/colony.png" width="200" alt="Kolonie mit Steckbrief, Aufgaben und Schnellaktionen"> | <img src="docs/screenshots/colony-stats.png" width="200" alt="Statistik einer Kolonie"> | <img src="docs/screenshots/timeline.png" width="200" alt="Timeline einer Kolonie"> |
| **Kolonien** | **Artenkatalog** | **Steckbrief** | **Benachrichtigungen** |
| <img src="docs/screenshots/colonies.png" width="200" alt="Kolonienliste"> | <img src="docs/screenshots/species-catalog.png" width="200" alt="Artenkatalog mit Suche und Filtern"> | <img src="docs/screenshots/species-sheet.png" width="200" alt="Steckbrief von Messor barbarus"> | <img src="docs/screenshots/notifications.png" width="200" alt="Benachrichtigungen: App, ntfy, E-Mail pro Thema"> |

<img src="docs/screenshots/desktop-dashboard.png" width="820" alt="Web-App am Desktop">

*Web-App im dunklen Design mit Beispieldaten; die Android-App sieht gleich aus.*

## Architektur

```text
 Android-App ──┐                        ┌─ Docker Compose ──────────────────────────────┐
 (offline,     │   HTTPS  /api/v1       │  proxy   Caddy (optional, HTTPS)               │
  NFC/QR)      ├──────────────────────► │  app     Go-Server: API + Web-App + Realtime   │
 Web-App ──────┘   /c/<code>  (QR/NFC)  │  db      PostgreSQL 18                         │
                                        │  backup  nächtliche Backups + Restore          │
                                        │  init    legt Verzeichnisse und Secrets an     │
                                        └──────────────── ./data ───────────────────────┘
```

Details: [Systemarchitektur](docs/02-systemarchitektur.md) · [Datenmodell](docs/03-datenmodell.md) · [Sync](docs/05-sync.md) · [NFC/QR](docs/06-nfc-qr-deeplinks.md) · [Sicherheit](docs/08-auth-sicherheit.md) · [alle Dokumente](docs/README.md)

## Installation

**Voraussetzungen:** Linux-Rechner, VPS, Mini-PC, Raspberry Pi 4/5 (64-bit) oder NAS mit **Docker** und **Compose v2.24+** (`docker compose version`); `amd64` oder `arm64`, ca. 300 MB RAM im Leerlauf. Für Internet-Zugriff zusätzlich eine Domain und die Ports 80/443.

```bash
git clone https://github.com/daschmidt1994/ant-colony-manager.git
cd ant-colony-manager
./scripts/init-env.sh          # erzeugt .env mit der IP dieses Rechners
docker compose up -d
docker compose ps              # nach ~1 Minute: alle Dienste "healthy"
```

1. **Setup-Code** holen: `docker compose logs app | grep -A1 Setup-Code`
2. `http://<server>:8080/setup` öffnen → Code eingeben → **Admin-Konto** anlegen
3. Erste Kolonie anlegen – sie bekommt automatisch einen QR-Code
4. [Android-App](#android-app) installieren, Server-Adresse eingeben, anmelden

**Unraid, Synology, Portainer/Dockhand:** fertige Compose-Datei [`deploy/docker-compose.yml`](deploy/docker-compose.yml), Anleitung [docs/17](docs/17-unraid-dockhand.md).

Compose lädt fertige Images von GHCR; sind sie nicht erreichbar, baut es sie selbst. Der Web-App-Build braucht mehr als 1 GB RAM – auf kleinen Rechnern fertige Images verwenden oder `ACM_WEB_BUILD=placeholder` setzen (Server ohne Weboberfläche).

### Im Internet mit HTTPS

```bash
./scripts/init-env.sh https://ants.example.com   # aktiviert Caddy
docker compose up -d
```

DNS auf den Server zeigen lassen, Ports 80/443 freigeben – Caddy holt das Zertifikat selbst. Heimnetz-Domains (`ants.home.arpa`) bekommen eine eigene CA (`ACM_TLS_MODE=internal`), deren Root-Zertifikat unter `data/caddy/data/caddy/pki/authorities/local/root.crt` liegt.

**Eigener Reverse Proxy:** [Nginx](deploy/examples/nginx.conf) · [Traefik](deploy/examples/compose.traefik.yml) · [Nginx Proxy Manager](deploy/examples/nginx-proxy-manager.md). Wichtig: `/api/v1/sync/events` nicht puffern, Uploads bis 64 MB erlauben, `TRUSTED_PROXIES` setzen.

## Konfiguration

Alles steht kommentiert in [`.env.example`](.env.example) (Heimnetz) bzw. [`.env.production.example`](.env.production.example) (Internet).

| Variable | Bedeutung |
|---|---|
| `PUBLIC_APP_URL` | Adresse für Browser, App und **QR/NFC-Links** (`<URL>/c/<code>`) |
| `DATA_DIR` | Ort aller Daten (Standard `./data`) |
| `PUID` / `PGID` | Besitzer der Dateien (Synology meist `1026`/`100`, Unraid `99`/`100`) |
| `REGISTRATION_MODE` | `invite` (Standard) · `open` · `closed` |
| `BACKUP_*` | Zeitplan und Aufbewahrung |
| `COMPOSE_PROFILES=proxy`, `ACM_DOMAIN` | eingebauter HTTPS-Proxy (Caddy) |
| `ACM_VERSION` | `latest` oder eine feste Version wie `1.4.0` |

E-Mail-Versand, Backup außer Haus, Home Assistant und KI-Zählung richtet der Administrator in der App ein: **Mehr → Server-Verwaltung**.

**Secrets** (Datenbank-Passwort, `JWT_SECRET`, `INSTANCE_SECRET`) erzeugt der Stack beim ersten Start selbst in `data/secrets/`; Werte in der `.env` haben Vorrang.

```text
data/
├── postgres/   Datenbank
├── uploads/    Fotos
├── backups/    Backups (ein Ordner pro Backup)
├── secrets/    automatisch erzeugte Secrets – mit sichern!
└── caddy/      Zertifikate (nur mit Proxy)
```

Container neu erstellen, updaten oder löschen berührt diese Daten nie – **nur das Löschen von `data/` löscht Daten.**

## Backup und Restore

Jede Nacht um 03:00 (`BACKUP_SCHEDULE`): Datenbank, Fotos (inkrementell, unveränderte kosten keinen Platz), Prüfsummen und Manifest. Aufbewahrung 7 täglich / 4 wöchentlich / 6 monatlich. `docker compose ps` zeigt den Backup-Dienst als *unhealthy*, wenn seit 26 h kein Backup gelang.

```bash
./scripts/backup.sh                       # jetzt sichern
./scripts/backup.sh --tag vor-umzug       # benanntes Backup (wird nie automatisch gelöscht)
./scripts/backup.sh list                  # Übersicht
./scripts/verify-backup.sh                # Prüfsummen + Test-Restore in eine temporäre DB
./scripts/restore.sh 2026-09-26T0300      # wiederherstellen
./scripts/restore.sh --from-offsite       # neuestes Backup vom Ziel außer Haus holen und einspielen
```

Das Restore prüft die Prüfsummen, legt vorher ein Sicherheits-Backup an, spielt Datenbank und Fotos ein und migriert ältere Backups automatisch. Noch nicht gesendete Offline-Einträge der Apps gehen nicht verloren.

**Außer Haus:** Ein Backup auf derselben Platte schützt nicht vor Defekt oder Diebstahl – unter Mehr → Server-Verwaltung → **Backup außer Haus** kopiert der Server jedes Backup zusätzlich nach Nextcloud, auf ein NAS (SMB, NFS) oder eine Storage Box, auf Wunsch verschlüsselt ([docs/25](docs/25-backup-ausser-haus.md)). Sichere außerdem `data/secrets/` und `.env`.

**Umzug auf neue Hardware:** Repository klonen, `.env` und `data/secrets/` übernehmen, Backup nach `data/backups/` kopieren, `docker compose up -d`, dann `./scripts/restore.sh <name>`.

## Update

```bash
./scripts/update.sh
```

Backup → `git pull` → neue Images → Neustart → warten bis *healthy*. Datenbank-Migrationen laufen beim Start automatisch; eine ältere App-Version startet nicht gegen ein neueres Schema.

## Android-App

**Download:** über [F-Droid](docs/18-fdroid.md) (automatische Updates) oder als [APK](https://github.com/daschmidt1994/ant-colony-manager/releases/latest/download/app-arm64-v8a-release.apk) ([alle Versionen](https://github.com/daschmidt1994/ant-colony-manager/releases)). Server-Adresse eingeben – oder in der Web-App „Mehr → Android-App verbinden“ öffnen und den QR-Code scannen. Schritt für Schritt: [docs/16](docs/16-anleitung-installieren-testen.md).

**NFC & QR:** Kolonie öffnen → ⋮ → „NFC-Tag zuweisen“ → Tag ans Handy halten; danach genügt Antippen, auch bei geschlossener App. QR-Etiketten: „Mehr → Etiketten drucken“ (Einzeletiketten, Brother 62 mm, A4-Bögen). Öffnen per Kamera-App mit eigener Domain: [docs/06](docs/06-nfc-qr-deeplinks.md#5-deep-links--app-links--die-ehrliche-einschränkung).

## Troubleshooting

| Problem | Lösung |
|---|---|
| `app` bleibt *unhealthy* | `docker compose logs app` – bei „configuration invalid“ steht die fehlende Variable dabei |
| Setup-Code weg | `docker compose logs app \| grep -A1 Setup-Code` (erscheint bei jedem Start, solange kein Konto existiert) |
| `storage not writable` / Rechte-Fehler | `PUID`/`PGID` an den Besitzer von `data/` anpassen, `docker compose up -d` |
| Passwort vergessen, kein E-Mail-Versand | `docker compose exec app /acm user reset-link du@example.com` |
| Admin-Rechte verloren | `docker compose exec app /acm user make-admin du@example.com` |
| QR-Codes zeigen falsche Adresse | `PUBLIC_APP_URL` korrigieren; alte Adresse in `LEGACY_APP_URLS`, damit vorhandene NFC-Tags weiter gehen |
| Netzwerk-Konflikt beim Start | `ACM_SUBNET` auf ein freies Netz ändern |
| Port 8080 belegt | `APP_PORT` ändern (und `PUBLIC_APP_URL`) |
| Backup-Dienst *unhealthy* | `docker compose logs backup`, `cat data/backups/status.json` |
| Handy erreicht den Server nicht | gleiches WLAN? Firewall auf dem Server (Port `APP_PORT`)? |
| Keine Erinnerungen bei geschlossener App | Viele Hersteller blockieren Hintergrund-Arbeit. **Xiaomi/Redmi/POCO:** App-Infos → **„Autostart“** an und Akku → **„Keine Einschränkungen“**; Samsung: Akku → „Nicht eingeschränkt“. App nicht aus den letzten Apps wegwischen. Diagnose: Mehr → Benachrichtigungen → „App auf diesem Gerät“ ([docs/20](docs/20-benachrichtigungen.md)) |

Status: `docker compose ps` · Logs: `docker compose logs -f` (ohne Passwörter, Tokens, Scan-Codes) · Diagnose: `http://<server>:8080/readyz`

## Entwicklung und Releases

```bash
cp .env.example .env
docker compose -f compose.yml -f compose.dev.yml up   # Hot Reload, Mailpit (http://localhost:8025)
./scripts/test-server.sh      # Backend-Tests gegen Wegwerf-PostgreSQL 18
./scripts/test-stack.sh       # End-to-End: Docker-Stack, Backup, Restore, Proxy
```

Go ist lokal nicht nötig (`./scripts/go.sh go …` nutzt einen Container); mehr in [server/README.md](server/README.md) und [app/README.md](app/README.md). Die CI testet Backend (mit Race-Detector), App, Web-App im Browser, ShellCheck und den Docker-Stack und baut Multi-Arch-Images nach GHCR.

**Versionen:** Server, Web-App und Android-App haben eine gemeinsame Version nach [SemVer](https://semver.org/lang/de/) in [`app/pubspec.yaml`](app/pubspec.yaml) – Fehlerbehebung `1.4.0 → 1.4.1`, neue Funktion `→ 1.5.0`, inkompatibel `→ 2.0.0`.

```bash
./scripts/release.sh 1.5.0     # Version setzen → Commit → Tag → pushen (fragt vorher nach)
./scripts/release.sh 2.0.0 --breaking "Was sich ändert und was vorher zu tun ist"
```

Der Tag baut die Server-Images (`1.5.0`, `1.5`, `latest`), das GitHub-Release mit den APKs und aktualisiert F-Droid. **`main`** ist der fertige Stand, **`dev`** der Teststand: Pushes auf `dev` bauen Images als `edge` und die Test-App **ACM Test** (läuft neben der echten App) für eine [Testinstanz](docs/19-testinstanz.md). Ablauf: getestet → `dev` nach `main` → Release per Tag. Mit `--breaking` zeigt die App vor dem Update eine rote Warnung mit der Reihenfolge *Backup → Server → App*.

## Lizenz

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only). Du darfst den Code nutzen, ändern und weitergeben; wer eine geänderte Version weitergibt oder als Dienst im Netz anbietet, muss den Quellcode unter derselben Lizenz offenlegen. Ohne Gewähr.

Ein Hobbyprojekt, entwickelt mit [Claude Code](https://claude.com/claude-code).
