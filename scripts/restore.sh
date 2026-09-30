#!/usr/bin/env sh
# Restore a backup (database + photos).
#   ./scripts/restore.sh NAME [--yes] [--no-safety-backup]
#   ./scripts/restore.sh --from-offsite [NAME] [--yes]   first download it from
#       the off-site target (WebDAV/SMB/folder, decrypted, checked) – newest if
#       no NAME. Target: settings in the app, or on a new server
#       ACM_OFFSITE_TYPE/URL/USER/PASSWORD; encrypted: ACM_OFFSITE_PASSPHRASE
#       (otherwise asked for).
# Steps: check → safety backup of the current state → stop app → restore →
# start app (migrations bring older backups up to date) → wait until healthy.
. "$(dirname -- "$0")/lib.sh"
require_env

name=""; yes=0; safety=1; offsite=0
for a in "$@"; do
  case "$a" in
    --yes|-y) yes=1 ;;
    --no-safety-backup) safety=0 ;;
    --from-offsite) offsite=1 ;;
    -*) die "unbekannte Option $a" ;;
    *) name=$(basename "$a") ;;
  esac
done
backups=$(volume_source backup /data/backups)
if [ "$offsite" = 1 ]; then
  say "Backup vom Ziel außer Haus holen …"
  [ -n "${ACM_OFFSITE_URL:-}" ] || { dc up -d db; wait_healthy db; }
  # the app image has the client; the backup folder is writable only here
  name=$(dc run --rm --no-deps -T -v "$backups:/restore" \
    -e ACM_OFFSITE_TYPE -e ACM_OFFSITE_URL -e ACM_OFFSITE_USER -e ACM_OFFSITE_PASSWORD -e ACM_OFFSITE_PASSPHRASE \
    app offsite-restore --to /restore ${name:+"$name"} | tail -n 1) || die "Herunterladen fehlgeschlagen"
  [ -n "$name" ] || die "Herunterladen fehlgeschlagen"
fi
[ -n "$name" ] || { run_backup_tool list; die "Bitte Backup-Namen angeben: ./scripts/restore.sh NAME"; }

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
