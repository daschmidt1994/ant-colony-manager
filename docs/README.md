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

## Offene Punkte für deine Freigabe

- [ ] Flutter Web als einzige Web-Oberfläche okay? (Alternative und Trade-offs: 01, Abschnitt 3)
- [ ] Go als Backend-Sprache okay? (Alternative: TypeScript/Fastify)
- [ ] Verifizierte Android App Links erfordern einen **eigenen APK-Build pro Domain** (siehe 06, Abschnitt 5). Standard-APK funktioniert trotzdem für NFC und In-App-Scan. Einverstanden?
- [ ] Registrierung standardmäßig **nur per Einladung** (nach Admin-Setup)?
- [ ] App-Sprache zunächst nur Deutsch (i18n-fähig vorbereitet) oder direkt DE + EN?
