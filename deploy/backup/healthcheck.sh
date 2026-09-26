#!/bin/sh
# Healthy if the last successful backup is younger than BACKUP_MAX_AGE_HOURS
# (default 26 h) – or the container started less than that ago.
set -eu
max=$(( ${BACKUP_MAX_AGE_HOURS:-26} * 3600 ))
now=$(date +%s)
status="${BACKUP_DIR:-/data/backups}/status.json"
if [ -f "$status" ]; then
  last=$(jq -r '.last_success // empty' "$status")
  if [ -n "$last" ] && [ $(( now - $(date -d "$last" +%s) )) -lt "$max" ]; then
    exit 0
  fi
fi
started=$(cat /tmp/started 2>/dev/null || echo 0)
[ $(( now - started )) -lt "$max" ] && exit 0
echo "no successful backup in the last ${BACKUP_MAX_AGE_HOURS:-26} hours"
exit 1
