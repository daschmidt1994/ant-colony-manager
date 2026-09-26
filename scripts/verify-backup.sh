#!/usr/bin/env sh
# Full check of a backup: checksums + test restore into a temporary database.
# The running instance is not touched.
#   ./scripts/verify-backup.sh [NAME]    (Standard: neuestes Backup)
. "$(dirname -- "$0")/lib.sh"
require_env
run_backup_tool verify "${1:-}"
