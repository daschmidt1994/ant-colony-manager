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
├── server/                        Go-Backend
│   ├── Dockerfile                 Multi-Stage: Flutter Web → Go → distroless
│   ├── Dockerfile.dev
│   ├── go.mod
│   ├── sqlc.yaml
│   ├── cmd/acm/main.go            serve | migrate | healthcheck | user | export
│   ├── internal/
│   │   ├── config/                ENV laden + validieren
│   │   ├── http/                  Router, Middleware (auth, ratelimit, logging, requestid)
│   │   ├── api/                   Handler (generierte Interfaces aus OpenAPI)
│   │   ├── authz/                 Berechtigungsprüfung
│   │   ├── service/
│   │   │   ├── auth/  colonies/  events/  sync/  scan/  photos/
│   │   │   ├── schedules/  rounds/  sensors/  export/  admin/
│   │   ├── store/                 sqlc-Output + Queries (*.sql)
│   │   ├── storage/               BlobStore: filesystem | s3
│   │   ├── jobs/                  Thumbnails, E-Mail-Digest, Tombstone-GC
│   │   ├── mail/                  SMTP + Templates
│   │   └── webui/                 //go:embed des Flutter-Web-Builds
│   ├── migrations/                goose: 00001_init.sql, …
│   └── test/                      API-/DB-Integrationstests (testcontainers-go)
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
│   ├── gen-api.sh                 OpenAPI → Go-Interfaces + Dart-Client
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
| API/DB | `testcontainers-go` + PostgreSQL 18 | Endpunkte, Berechtigungen (fremder Nutzer → 404), Idempotenz, Migrationen |
| E2E | `docker compose` in CI + Playwright (Web) | Installation, `/c/<token>`-Web-Fallback, Backup/Restore |
