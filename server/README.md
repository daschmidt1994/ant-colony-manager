# Ant Colony Manager – Backend

Go-Server für API, Sync und Auslieferung der Web-App. Ein statisches Binary (`acm`), PostgreSQL 18 als einzige Abhängigkeit.

## Schnellstart für Entwickler

Voraussetzung ist nur Docker; Go läuft im Container.

```bash
scripts/test-server.sh                 # alle Tests gegen Wegwerf-PostgreSQL 18
scripts/test-server.sh -run TestSync -v
scripts/go.sh go vet ./...             # beliebige Go-Befehle
scripts/go.sh go build -o /tmp/acm ./cmd/acm
```

Lokale Go-Installation (≥ 1.26) funktioniert ebenso:

```bash
cd server
TEST_DATABASE_URL=postgres://postgres:test@localhost:55432/postgres?sslmode=disable go test ./...
```

## Kommandos

| Befehl | Zweck |
|---|---|
| `acm serve` | Server starten (Standard); migriert die Datenbank automatisch |
| `acm migrate status\|up` | Migrationsstand anzeigen / anwenden |
| `acm healthcheck` | Exit-Code 0, wenn `/readyz` ok ist (Docker-Healthcheck) |
| `acm user reset-link <mail>` | Passwort-Reset-Link ohne SMTP |
| `acm user make-admin <mail>` | Administratorrechte vergeben |
| `acm version` | Version |

Konfiguration ausschließlich über Umgebungsvariablen (siehe `docs/07-docker.md`). Der Server startet nicht mit fehlenden, zu kurzen oder offensichtlich gewählten Secrets.

## Architektur in einem Satz

**Jede Änderung ist eine Operation (`service.Op`), die genau einmal über `Service.ApplyOp` angewendet wird** – egal ob sie aus `POST /api/v1/colonies` oder aus `POST /api/v1/sync/push` stammt.

```text
HTTP (internal/api)  →  Service (internal/service)  →  PostgreSQL
                          ├─ ApplyOp: Idempotenz → Berechtigung → Hooks → Konflikte → Referenzen → SQL
                          ├─ Pull/Snapshot: change_log + Sichtbarkeit
                          └─ Lese-Abfragen: Kolonieliste, Dashboard, Timeline …
PostgreSQL-Trigger: version (= globaler seq), change_log, pg_notify für SSE
```

### Sicherheit auf Datenebene
- Schreibbare Felder stehen pro Tabelle in `service/entities.go` (Whitelist). Alles andere wird ignoriert und im Ergebnis als `ignored_fields` gemeldet.
- Werte werden per `jsonb_populate_record` von PostgreSQL typisiert; CHECK-Constraints validieren. Spaltennamen stammen nur aus der Whitelist.
- Jede Referenz (Standort, Art, Nest, Kolonie …) wird gegen den Besitzer bzw. die Kolonie geprüft – niemand kann fremde Datensätze verknüpfen.
- Fremde Kolonien sind immer 404 (`TestTenantIsolation` prüft jeden Endpunkt).

## Eine neue Entität hinzufügen

1. Tabelle in einer neuen Migration `internal/db/migrations/000N_….sql` anlegen – mit `id uuid`, `version bigint`, `updated_at`, `deleted_at` und Sync-Triggern:
   ```sql
   CREATE TRIGGER x_sync_stamp BEFORE INSERT OR UPDATE ON x FOR EACH ROW EXECUTE FUNCTION sync_stamp();
   CREATE TRIGGER x_sync_log  AFTER INSERT OR UPDATE ON x FOR EACH ROW EXECUTE FUNCTION sync_log();
   ```
2. In `service/entities.go` eintragen: `Scope`, `Fields`, `Refs`, ggf. Hooks und `Collection` (REST-Pfad).
3. REST (`/api/v1/<collection>`), Sync-Push/-Pull, Snapshot und Export funktionieren damit automatisch.
4. Falls eigene Endpunkte nötig sind: in `api/server.go` registrieren **und** in `api/openapi.yaml` dokumentieren (sonst schlägt `TestEveryRouteIsDocumented` fehl).
5. Den Mandanten-Test `TestTenantIsolation` um die neuen Pfade ergänzen.

Beim Start prüft `service.New`, dass alle Felder der Registry im Schema existieren.

## Tests

| Paket | Inhalt |
|---|---|
| `internal/api` | Integrationstests über HTTP: Auth, Setup, Rate-Limits, Mandantentrennung, Sync (genau-einmal, Konflikte, Tombstones, Freigaben), Scan/QR/NFC, Fotos (Metadaten-Entfernung), Sensoren, Export, Realtime, OpenAPI-Abdeckung |
| `internal/service` | Fälligkeiten gegen `test-vectors/due.json` (gemeinsam mit der App), EXIF-Parser, Hilfsfunktionen |
| `internal/auth`, `config`, `ratelimit` | Unit-Tests |

Jeder Integrationstest bekommt eine eigene Datenbank (Kopie einer migrierten Template-DB).
