#!/bin/sh
# Example: copy local backups to an offsite restic repository (external disk,
# SFTP, S3, Backblaze …). Run on the host after the nightly backup, e.g. cron:
#   30 4 * * *  /opt/ant-colony-manager/deploy/examples/offsite-restic.sh
# Requires: restic, RESTIC_REPOSITORY and RESTIC_PASSWORD (or _FILE) in the environment.
set -eu
cd "$(dirname "$0")/../.."
BACKUPS=${DATA_DIR:-./data}/backups
restic snapshots >/dev/null 2>&1 || restic init
# Only complete backups; restic deduplicates, so hard-linked photos cost nothing extra.
restic backup --tag ant-colony-manager --exclude '.tmp-*' --exclude '.lock' "$BACKUPS"
restic forget --tag ant-colony-manager --keep-daily 7 --keep-weekly 8 --keep-monthly 12 --prune
restic check --read-data-subset=5%
