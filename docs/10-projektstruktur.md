# 10 – Projekt-/Ordnerstruktur

Monorepo – ein `git clone` enthält alles, was für Installation und Entwicklung nötig ist.

```text
ant-colony-manager/
├── README.md                      Installation, Quick Start, Troubleshooting
├── CHANGELOG.md
├── LICENSE                        (Vorschlag: AGPL-3.0 – schützt Self-Hosting-Charakter; alternativ MIT)
├── compose.yml                    Produktion
├── compose.dev.yml                Entwicklung (Hot Reload, Mailpit, DB-Port)
├── .env.example                   LAN-/Einsteiger-Defaults
├── .env.production.example        sichere Produktionswerte
│
├── api/
│   └── openapi.yaml               API-Vertrag (Single Source of Truth)
│
├── server/                        Go-Backend (Stand Phase 3)
│   ├── README.md                  Entwickler-Anleitung Backend
│   ├── go.mod
│   ├── cmd/acm/main.go            serve | migrate | healthcheck | user | version
│   └── internal/
│       ├── config/                ENV laden + validieren (fail fast)
│       ├── db/                    Pool, Transaktionen, Migrations-Runner
│       │   └── migrations/        0001_init.sql, … (eingebettet)
│       ├── auth/                  argon2id, JWT, Tokens, Passwortregeln
│       ├── service/               Fachlogik – EIN Schreibpfad (ApplyOp) für REST und Sync
│       │   ├── entities.go        Registry: welche Tabellen/Felder synchronisiert & schreibbar sind
│       │   ├── apply.go           Idempotenz, Berechtigung, Konflikte, Referenzen, Tombstones
│       │   ├── hooks.go           Entitäts-Regeln (Event-Details, Koloniennummer, Winterruhe …)
│       │   ├── sync.go            Push, Pull, Snapshot, Konflikte
│       │   ├── due.go             Fälligkeiten/Ampel (Zwilling des Dart-DueCalculators)
│       │   ├── queries.go         Kolonieliste, Übersicht, Timeline, Dashboard, Scan, Mitglieder
│       │   ├── accounts.go        Setup, Registrierung, Sessions, Passwörter, App-Verbindung
│       │   ├── photos.go          Upload, Neukodierung, EXIF, signierte URLs
│       │   ├── sensors.go  admin.go  maintenance.go  rest.go
│       ├── api/                   HTTP: Router, Middleware, Handler, SSE-Broker + Integrationstests
│       ├── storage/               BlobStore (Dateisystem)
│       ├── mail/                  SMTP
│       ├── ratelimit/             Token-Bucket in-memory
│       ├── testenv/               Test-Server gegen echte PostgreSQL (DB pro Test)
│       └── webui/dist/            eingebettete Web-App (bis Phase 5: Platzhalter)
│
├── app/                           Flutter (Android + Web, später iOS)
│   ├── pubspec.yaml
│   ├── android/                   Manifest (NFC-/Deep-Link-Filter), Signing via ENV
│   ├── web/                       index.html, Service Worker, sqlite3.wasm
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app/                   App-Widget, Router (go_router), Theme (hell/dunkel), l10n
│   │   ├── core/                  Result/Fehlertypen, Logging, Plattform-Abstraktionen (NFC nur Android)
│   │   ├── domain/                Modelle (freezed), DueCalculator, TrafficLight, Enums  ← reines Dart
│   │   ├── data/
│   │   │   ├── local/             Drift: Tabellen, DAOs, Migrationen
│   │   │   ├── remote/            generierter OpenAPI-Client, Auth-Interceptor
│   │   │   ├── sync/              Outbox, SyncEngine, PhotoUploader, ConflictHandler
│   │   │   └── repositories/      ColonyRepository, EventRepository, ScanRepository …
│   │   ├── features/              je Feature: presentation/ (Screens, Widgets) + application/ (Provider, Use-Cases)
│   │   │   ├── auth/  onboarding/  dashboard/  colonies/  colony_detail/
│   │   │   ├── quick_actions/     Füttern, Wasser, Reinigung, Kontrolle, Notiz, Messung, Foto
│   │   │   ├── scan/              QR-Scanner, NFC-Reader, Token-Resolver
│   │   │   ├── nfc_assign/  labels/  timeline/  photos/  care_round/
│   │   │   ├── schedules/  locations/  statistics/  settings/  admin/
│   │   └── shared/                gemeinsame Widgets (BigActionButton, StatusChip, …)
│   ├── test/                      Unit- + Widget-Tests
│   ├── integration_test/          Geräte-/Emulator-Tests (Scan → Kolonie, Offline-Sync)
│   └── test-vectors/ → ../test-vectors
│
├── test-vectors/                  gemeinsame Testfälle Dart ⇄ Go (Fälligkeiten, Token-Format, Sync-Merge)
│
├── deploy/
│   ├── backup/                    Dockerfile, backup.sh, restore-in-container.sh, healthcheck.sh, crontab
│   ├── caddy/Caddyfile
│   └── examples/                  traefik.yml, nginx.conf, nginx-proxy-manager.md, restic/rclone
│
├── scripts/
│   ├── init-env.sh                .env mit Zufalls-Secrets erzeugen
│   ├── backup.sh  restore.sh  verify-backup.sh  update.sh
│   ├── build-apk.sh               eigene APK mit App-Link-Domain
│   ├── go.sh                      Go-Toolchain im Container
│   ├── test-server.sh             Backend-Tests gegen Wegwerf-PostgreSQL 18
│   ├── gen-api.sh                 OpenAPI → Dart-Client (Phase 5)
│   └── test-backup-restore.sh
│
├── docs/                          ← Phase-1-Dokumente (diese Dateien), später Nutzer- und Admin-Doku
│
└── .github/workflows/
    ├── ci.yml                     Lint, Tests (Go, Dart), API-Tests gegen echte DB
    ├── images.yml                 Multi-Arch-Images (amd64/arm64) → GHCR
    ├── apk.yml                    Release-APK (+ Variante mit eigener Domain über Secrets)
    └── backup-restore.yml         End-to-End-Backup/Restore-Test
```

## Teststrategie (Überblick, Details in Phase 3/5)

| Ebene | Werkzeug | Schwerpunkt |
|---|---|---|
| Domain (Dart) | `test` | Fälligkeiten, Ampel, Winterruhe, Outbox-Verdichtung |
| Widgets | `flutter_test` | Quick Actions, Kolonie-Startseite, Scanner-Flows |
| Integration (App) | `integration_test` + Emulator | QR → Kolonie, NFC-Intent → Kolonie, Offline → Sync → genau 1× |
| Backend Unit | `go test` | Services, authz-Matrix, Konflikt-Merge |
| API/DB | `scripts/test-server.sh` (PostgreSQL 18 im Container, geklonte DB pro Test) | Endpunkte, Berechtigungen (fremder Nutzer → 404), Idempotenz, Sync, Migrationen, Doku-Abdeckung der Routen |
| E2E | `docker compose` in CI + Playwright (Web) | Installation, `/c/<token>`-Web-Fallback, Backup/Restore |
