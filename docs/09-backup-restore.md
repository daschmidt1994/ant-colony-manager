# 09 – Backup & Restore

## 1. Was wird gesichert?

| Inhalt | Methode |
|---|---|
| PostgreSQL | `pg_dump --format=custom --compress=zstd` (konsistenter Snapshot im laufenden Betrieb) |
| Fotos/Uploads | `rsync --link-dest=<vorheriges Backup>` → jedes Backup ist ein vollständiger Ordner, unveränderte Dateien sind Hardlinks und belegen keinen zusätzlichen Platz |
| Konfiguration | `.env` **nur** mit `BACKUP_INCLUDE_ENV=true` (enthält Secrets), sonst eine Kopie mit geschwärzten Secrets zur Dokumentation |
| Metadaten | `manifest.json`: App-Version, Schema-Version, Zeitpunkt, Zeilenzahlen je Tabelle, Anzahl/Größe Fotos, SHA-256 aller Dateien der Sicherung |

Weil Fotos content-adressiert und unveränderlich gespeichert werden, sind tägliche Backups auch bei vielen GB Fotos schnell und klein.

## 2. Aufbau

```text
data/backups/
├── 2026-09-25T0300/
├── 2026-09-26T0300/
│   ├── db.dump
│   ├── uploads/            (Hardlinks auf 2026-09-25, nur neue Dateien echt)
│   ├── env.redacted
│   ├── manifest.json
│   └── OK                  (wird zuletzt geschrieben → unvollständige Backups sind erkennbar)
├── 2026-09-26T1412-pre-update/
└── latest -> 2026-09-26T0300
```

## 3. Ablauf & Zeitplan

- Container `backup` führt `backup.sh` per `supercronic` nach `BACKUP_SCHEDULE` aus (Standard täglich 03:00).
- **Aufbewahrung (GFS):** 7 tägliche, 4 wöchentliche (Sonntag), 6 monatliche (1. des Monats); `pre-update`/manuelle Backups werden nicht automatisch gelöscht (nur mit `--prune-manual`).
- Nach jedem Backup: **automatische Verifikation** – `pg_restore --list` auf den Dump, Prüfsummen der neuen Dateien, Zeilenzahlen plausibel (kein Einbruch > 50 % ohne Warnung).
- Status landet in `data/backups/status.json` → Healthcheck des Containers und Anzeige im Admin-Bereich („Letztes Backup: heute 03:00, 412 MB, verifiziert ✔“).
- Optional E-Mail bei Fehlschlag (SMTP).

Manuell:
```bash
./scripts/backup.sh                               # = docker compose exec backup /app/backup.sh
./scripts/backup.sh --tag vor-umzug
docker compose exec backup /app/backup.sh --list
```

**Offsite (dringend empfohlen, optional):** `data/backups` ist ein normaler Ordner → per restic/borg/rclone/Hyper Backup (Synology) auf externe Platte oder Cloud. Beispiel-Konfigurationen für restic und rclone in `deploy/examples/`. Eine lokale Sicherung auf derselben Platte schützt nicht vor Plattendefekt – die README sagt das deutlich.

## 4. Restore

```bash
./scripts/restore.sh data/backups/2026-09-26T0300
```

Ablauf des Skripts:
```text
1. Prüfen: OK-Datei vorhanden, manifest.json lesbar, Prüfsummen stimmen
2. Anzeigen: Zeitpunkt, App-Version, Anzahl Kolonien/Events/Fotos → Bestätigung „RESTORE“ tippen
3. Sicherheits-Backup des aktuellen Zustands (--tag pre-restore), sofern DB erreichbar
4. docker compose stop app
5. Datenbank neu anlegen (DROP/CREATE DATABASE) → pg_restore --exit-on-error --no-owner
6. uploads/ per rsync --delete aus dem Backup zurückspielen
7. docker compose start app → Migrationen heben ältere Backups automatisch auf den aktuellen Stand
8. Warten auf healthy, Zeilenzahlen mit manifest.json vergleichen → Ergebnis ausgeben
```

Weitere Fälle:
- **Umzug auf neuen Server:** Repo klonen, `.env` übernehmen (oder aus Backup mit `BACKUP_INCLUDE_ENV=true`), Backup-Ordner kopieren, `restore.sh` ausführen. Dokumentiert als eigener Abschnitt „Migration auf neue Hardware“.
- **Backup einer neueren App-Version** in ältere Installation → Skript bricht ab (Schema neuer als App).
- **Clients nach Restore:** Der Server erhöht beim Restore eine `restore_epoch` in `instance_settings`. Apps erkennen den Wechsel beim nächsten Sync, pushen ihre ausstehende Outbox (idempotent, dadurch gehen Offline-Einträge seit dem Backup **nicht verloren**) und führen danach einen Snapshot-Resync durch.

## 5. „Erst fertig, wenn Restore getestet wurde“

- **CI-Test (`scripts/test-backup-restore.sh`):** Stack starten → Testdaten (Nutzer, 50 Kolonien, Events, Fotos) per API anlegen → Backup → Daten verändern/löschen → Restore → Zeilenzahlen, Stichproben per API und SHA-256 der Fotos vergleichen. Läuft bei jedem Release.
- **Für Betreiber:** `./scripts/verify-backup.sh <backup>` stellt ein Backup in einen **temporären** PostgreSQL-Container wieder her (ohne die laufende Instanz anzufassen) und gibt einen Bericht aus. Empfehlung in der README: einmal pro Quartal ausführen.

## 6. Abgrenzung: Export vs. Backup

| | Export (Nutzer) | Backup (Admin) |
|---|---|---|
| Umfang | eigene Daten eines Nutzers | gesamte Instanz |
| Format | JSON (vollständig, dokumentiertes Schema), CSV (ZIP), Fotos (ZIP, sprechende Namen) | `pg_dump` + Dateien |
| Zweck | Datenportabilität, Auswertung in Excel, Wechsel zu anderer Software | Wiederherstellung nach Ausfall |
| Wiederimport | JSON-Import in eine (andere) Instanz geplant (Phase 9) | `restore.sh` |
