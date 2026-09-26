#!/usr/bin/env sh
# Backup now (or manage backups).
#   ./scripts/backup.sh                  Backup erstellen
#   ./scripts/backup.sh --tag vor-umzug  Backup mit Namen (wird nie automatisch gelöscht)
#   ./scripts/backup.sh list             Backups anzeigen
. "$(dirname -- "$0")/lib.sh"
require_env
case "${1:-}" in
  list) run_backup_tool list ;;
  *) run_backup_tool backup "$@" ;;
esac
