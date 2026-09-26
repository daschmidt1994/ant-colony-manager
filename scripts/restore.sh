#!/usr/bin/env sh
# Restore a backup (database + photos).
#   ./scripts/restore.sh NAME [--yes] [--no-safety-backup]
# Steps: check → safety backup of the current state → stop app → restore →
# start app (migrations bring older backups up to date) → wait until healthy.
. "$(dirname -- "$0")/lib.sh"
require_env

name=""; yes=0; safety=1
for a in "$@"; do
  case "$a" in
    --yes|-y) yes=1 ;;
    --no-safety-backup) safety=0 ;;
    -*) die "unbekannte Option $a" ;;
    *) name=$(basename "$a") ;;
  esac
done
[ -n "$name" ] || { run_backup_tool list; die "Bitte Backup-Namen angeben: ./scripts/restore.sh NAME"; }

backups=$(volume_source backup /data/backups)
uploads=$(volume_source app /data/uploads)
[ -f "$backups/$name/OK" ] || die "Backup $name nicht gefunden oder unvollständig ($backups)"

say "Backup $name"
jq -r '"  erstellt:  \(.created_at)\n  Schema:    \(.schema_version)\n  Kolonien:  \(.counts.colonies)\n  Ereignisse: \(.counts.colony_events)\n  Fotos:     \(.uploads.files)"' "$backups/$name/manifest.json"
warn "Der aktuelle Datenbestand wird durch dieses Backup ERSETZT."
if [ "$yes" != 1 ]; then
  printf 'Zum Fortfahren RESTORE eingeben: '
  read -r answer
  [ "$answer" = RESTORE ] || die "abgebrochen"
fi

dc up -d db
wait_healthy db
if [ "$safety" = 1 ]; then
  say "Sicherheits-Backup des aktuellen Stands …"
  run_backup_tool backup --tag pre-restore || warn "Sicherheits-Backup fehlgeschlagen – fahre trotzdem fort"
fi
say "App anhalten …"
dc stop app
say "Wiederherstellen …"
dc run --rm --no-deps -T -v "$uploads:/restore/uploads" backup restore "$name"
say "App starten …"
dc up -d app
wait_healthy app
say "Restore abgeschlossen. Apps laden beim nächsten Sync automatisch den wiederhergestellten Stand;"
say "offline erfasste, noch nicht gesendete Einträge werden dabei nachgereicht."
