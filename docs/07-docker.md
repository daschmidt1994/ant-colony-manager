# 07 – Docker-Compose-Architektur

## 1. Container

| Service | Image | Pflicht | Aufgabe |
|---|---|---|---|
| `app` | `ghcr.io/<org>/ant-colony-manager` (amd64 + arm64) | ✔ | Go-API + eingebettete Flutter-Web-App + Hintergrundjobs + Migrationen |
| `db` | `postgres:18-alpine` | ✔ | Datenbank |
| `backup` | `ghcr.io/<org>/ant-colony-manager-backup` | ✔ (abschaltbar) | geplante Backups, Retention, manuelle Backups/Restores |
| `init` | Backup-Image | ✔ (einmalig) | Verzeichnisse + Rechte + Secrets beim Start |
| `proxy` | `caddy:2-alpine` | Profil `proxy` | HTTPS (Let's Encrypt oder interne CA) |

**Bewusst weggelassen:** separater Web-Container (Web ist im `app`-Image eingebettet), Redis (Rate-Limits/Jobs in-process bzw. in PostgreSQL), Worker (Goroutinen), MinIO/Storage-Container (Dateisystem-Volume; S3 optional per ENV). Weniger Container = weniger RAM auf Pi/NAS und weniger Update-Aufwand.

## 2. compose.yml (umgesetzt in Phase 4)

Die verbindliche Datei ist [`compose.yml`](../compose.yml). Gegenüber dem ursprünglichen Entwurf:

| Punkt | Umsetzung |
|---|---|
| **`init`-Dienst** | Einmal-Container (Backup-Image) legt `uploads/`, `backups/`, `secrets/` mit `PUID:PGID` an und **erzeugt fehlende Secrets** → `cp .env.example .env && docker compose up -d` genügt |
| Secrets | `data/secrets/{postgres_password,jwt_secret,instance_secret}` (0440); Übergabe per `*_FILE`-Variablen, Werte aus `.env` haben Vorrang |
| `app` | läuft als `PUID:PGID`, `read_only`, `cap_drop: ALL`, `no-new-privileges`, Healthcheck `/acm healthcheck` |
| `backup` | basiert auf `postgres:18-alpine` (identische `pg_dump`-Version), liest Fotos nur lesend |
| Netzwerk | eigenes Subnetz `ACM_SUBNET` (für `TRUSTED_PROXIES` berechenbar), kein fester Netzwerkname → mehrere Stacks parallel möglich |
| Images ohne Registry | fehlt ein Image auf GHCR, baut Compose es lokal (`build:` ist hinterlegt) |

## 3. compose.dev.yml (Entwicklung)

```yaml
services:
  app:
    build: { context: ., dockerfile: server/Dockerfile.dev }  # Go + air (Hot Reload)
    volumes: [./server:/src]
    environment: { APP_ENV: development, LOG_FORMAT: text }
    user: root
    read_only: false
  db:
    ports: ["5432:5432"]
  mailpit:                                                   # E-Mails abfangen
    image: axllent/mailpit
    ports: ["8025:8025"]
```
Umgesetzt mit `air` (Hot Reload, getestet) und Mailpit; `/tmp` ist in Produktion ein `noexec`-tmpfs, daher baut `air` nach `/root/.air`.
Flutter läuft in der Entwicklung außerhalb von Docker (`flutter run -d chrome` / Android-Gerät) mit Hot Reload gegen `http://localhost:8080`.
Aufruf: `docker compose -f compose.yml -f compose.dev.yml up`.

## 4. Images & Multi-Arch

**`server/Dockerfile`** (Multi-Stage):
```text
Stage 1  ghcr.io/cirruslabs/flutter  --platform=$BUILDPLATFORM   → flutter build web --wasm --release
Stage 2  golang:1.25-alpine          --platform=$BUILDPLATFORM   → CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH
                                                                   go build (Web-Build per //go:embed)
Stage 3  gcr.io/distroless/static:nonroot                         → /acm  (~25 MB)
```
Beide Build-Stufen laufen nativ auf der Build-Maschine, nur das Ziel-Binary wird cross-kompiliert → schnelle Builds für `linux/amd64` und `linux/arm64` ohne QEMU. CI: `docker buildx build --platform linux/amd64,linux/arm64 --push`.

**`deploy/backup/Dockerfile`**: `postgres:18-alpine` + `rsync` + `zstd` + `supercronic` (Cron ohne Root) + `jq`. Das Server-Image wurde lokal für `amd64` und `arm64` gebaut (24 MB); das Backup-Image enthält `RUN`-Schritte und wird für `arm64` in der CI mit QEMU gebaut.

## 5. Persistente Daten

```text
./data/                   (DATA_DIR, z. B. /volume1/docker/acm auf Synology)
├── postgres/             Datenbank
├── uploads/              Fotos (content-adressiert: ab/cd/<sha256>.jpg + thumbs/)
├── backups/              Backups
└── caddy/                Zertifikate (nur mit Proxy)
```
- Bind-Mounts statt anonymer Volumes → für NAS-Nutzer sichtbar, einfach zu sichern.
- Nichts Persistentes liegt im Container → `docker compose down`, `pull`, `up --build` sind gefahrlos. **Nur** `docker compose down -v` oder Löschen von `./data` entfernt Daten (in README deutlich markiert).
- `PUID`/`PGID` für NAS-Rechte (Synology: typischerweise `1026:100`).

## 6. Konfiguration

`.env.example` (Entwicklung/LAN-freundlich) und `.env.production.example` (sichere Werte, HTTPS Pflicht). Auszug:

```env
# --- Öffentliche Adresse (QR/NFC-Links, E-Mails) ---
PUBLIC_APP_URL=https://ants.example.com
LEGACY_APP_URLS=                     # frühere Domains, die weiterhin akzeptiert werden
ACM_DOMAIN=ants.example.com          # nur für Caddy
APP_PORT=8080
APP_BIND=0.0.0.0
TRUSTED_PROXIES=172.16.0.0/12        # Quelle von X-Forwarded-For

# --- Datenbank ---
POSTGRES_DB=acm
POSTGRES_USER=acm
POSTGRES_PASSWORD=                   # Pflicht: openssl rand -base64 32

# --- Secrets ---
JWT_SECRET=                          # Pflicht, ≥ 32 Byte: openssl rand -base64 48
INSTANCE_SECRET=                     # Pflicht: HMAC für NFC-UIDs, signierte Foto-URLs

# --- Speicher ---
DATA_DIR=./data
STORAGE_DRIVER=filesystem            # filesystem | s3
S3_ENDPOINT=  S3_BUCKET=  S3_ACCESS_KEY=  S3_SECRET_KEY=
PHOTO_KEEP_ORIGINAL=false
UPLOAD_MAX_MB=20

# --- Konten ---
REGISTRATION_MODE=invite             # open | invite | closed
SESSION_REFRESH_DAYS=90

# --- E-Mail (optional; ohne SMTP: Reset-Links über Admin/CLI) ---
SMTP_HOST=  SMTP_PORT=587  SMTP_USER=  SMTP_PASSWORD=  SMTP_FROM=  SMTP_TLS=starttls

# --- Backups ---
BACKUP_SCHEDULE=0 3 * * *
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=6
BACKUP_INCLUDE_ENV=false

# --- Android App Links (nur für eigene APK) ---
ANDROID_APP_ID=at.antcolony.manager
ANDROID_CERT_SHA256=

# --- Betrieb ---
LOG_LEVEL=info                       # debug | info | warn | error
LOG_FORMAT=json                      # json | text
TZ=Europe/Vienna
```

Der Server **startet nicht**, wenn Pflicht-Secrets fehlen, zu kurz sind oder Beispielwerte enthalten (klare Fehlermeldung im Log). Leere Secrets in der `.env` erzeugt der `init`-Dienst automatisch; `scripts/init-env.sh` trägt zusätzlich die öffentliche Adresse ein.

## 7. Healthchecks & Logs

| Service | Check | Bedeutung |
|---|---|---|
| db | `pg_isready` | DB nimmt Verbindungen an |
| app | `/acm healthcheck` → `GET /readyz` | DB-Query ok, Upload-Verzeichnis beschreibbar, Migrationen aktuell |
| backup | `healthcheck.sh` | letztes erfolgreiches Backup jünger als 26 h |
| proxy | Caddy Admin-API | Proxy läuft |

`docker compose ps` zeigt damit auf einen Blick `healthy`/`unhealthy` – ein fehlgeschlagenes Backup wird sichtbar.

Logs: strukturiert (JSON, `slog`), eine Zeile pro Request mit Request-ID, Methode, Pfad (**ohne** Query-Strings bei `/files/` und `/c/`), Status, Dauer, User-ID. Ein zentraler Redaktor entfernt `Authorization`, `Cookie`, Passwörter, Tokens, Signaturen. Rotation über den `json-file`-Treiber (5 × 10 MB).

## 8. Migrationen & Updates

- Migrationen sind im Binary eingebettet (`goose`) und laufen **automatisch beim Start**, abgesichert durch einen PostgreSQL-Advisory-Lock. Nur vorwärts, jede Migration in einer Transaktion.
- Manuell: `docker compose exec app /acm migrate status|up`.
- `app` verweigert den Start, wenn das DB-Schema **neuer** ist als das Binary (Downgrade-Schutz).

Update:
```bash
./scripts/update.sh
#  = ./scripts/backup.sh --tag pre-update
#    git pull
#    docker compose pull
#    docker compose up -d --build
#    warten bis healthy, sonst Hinweis auf Restore des pre-update-Backups
```
Versionen folgen SemVer und entstehen mit `./scripts/release.sh x.y.z` (Tag `vx.y.z`). Änderungen stehen in den [GitHub-Releases](https://github.com/daschmidt1994/ant-colony-manager/releases). `latest` ist das neueste Release, `edge` der getestete Stand von `main`; `ACM_VERSION` in `.env` erlaubt, auf eine Version festzunageln.
