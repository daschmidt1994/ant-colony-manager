#!/usr/bin/env sh
# Update to the newest version:
#   Backup (pre-update) → git pull → images holen/bauen → neu starten → prüfen
. "$(dirname -- "$0")/lib.sh"
require_env
say "1/4 Backup vor dem Update …"
if [ "$(container_health db)" = healthy ]; then
  run_backup_tool backup --tag pre-update
else
  warn "Datenbank läuft nicht – Backup übersprungen"
fi
say "2/4 Neueste Version holen …"
if [ -d .git ]; then git pull --ff-only; else warn "kein git-Repository – überspringe git pull"; fi
say "3/4 Images aktualisieren …"
dc pull --ignore-buildable --quiet || warn "pull fehlgeschlagen – verwende lokale Images"
dc up -d --build --remove-orphans
say "4/4 Warten, bis alles läuft …"
wait_healthy db
wait_healthy app
dc ps
say "Update abgeschlossen. Bei Problemen: ./scripts/restore.sh <pre-update-Backup> (siehe ./scripts/backup.sh list)"
