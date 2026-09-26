#!/bin/sh
# Restore a backup (runs inside the backup container). The app must be stopped
# and the uploads directory mounted writable at /restore/uploads – use
# scripts/restore.sh on the host, which does both.
set -eu
BACKUP_DIR=${BACKUP_DIR:-/data/backups}
TARGET_UPLOADS=${TARGET_UPLOADS:-/restore/uploads}
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') restore: $*"; }
die() { log "ERROR: $*"; exit 1; }

[ $# -ge 1 ] || die "usage: restore NAME"
p="$BACKUP_DIR/$(basename "$1")"
[ -f "$p/OK" ] && [ -f "$p/manifest.json" ] || die "$1 is not a complete backup"
[ -d "$TARGET_UPLOADS" ] || die "$TARGET_UPLOADS is not mounted"

log "checking $1"
echo "$(jq -r .db_dump.sha256 "$p/manifest.json")  $p/db.dump" | sha256sum -c --quiet || die "db.dump checksum mismatch – backup damaged"
(cd "$p" && sha256sum -c --quiet uploads.sha256) || die "upload checksums do not match – backup damaged"

active=$(psql -X -d postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname = '$PGDATABASE' AND pid <> pg_backend_pid()")
[ "$active" = "0" ] || log "closing $active open connection(s)"

log "restoring database"
dropdb --maintenance-db=postgres --if-exists --force "$PGDATABASE"
createdb --maintenance-db=postgres "$PGDATABASE"
pg_restore --exit-on-error --no-owner --no-privileges -d "$PGDATABASE" "$p/db.dump" || die "pg_restore failed"

# Clients must never miss changes after going back in time: move the change
# counter beyond anything issued before and raise the tombstone horizon, so
# every app pushes its pending offline changes and then reloads a snapshot.
psql -X -v ON_ERROR_STOP=1 -q -d "$PGDATABASE" <<'SQL'
UPDATE sync_counter SET value = GREATEST(value, (extract(epoch FROM clock_timestamp()) * 1000)::bigint);
INSERT INTO instance_settings (key, value) VALUES ('tombstone_horizon_seq', to_jsonb((SELECT value FROM sync_counter)))
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now();
INSERT INTO instance_settings (key, value) VALUES ('last_restore', jsonb_build_object('at', now()))
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now();
SQL

log "restoring uploads"
rsync -a --delete "$p/uploads/" "$TARGET_UPLOADS/"

q="SELECT json_build_object("
sep=""
for t in $(jq -r '.counts | keys[]' "$p/manifest.json"); do
  q="$q$sep'$t', (SELECT count(*) FROM $t)"; sep=", "
done
got=$(psql -X -Atc "$q)")
want=$(jq -S -c .counts "$p/manifest.json")
[ "$(echo "$got" | jq -S -c .)" = "$want" ] || die "row counts differ after restore: expected $want, got $got"
files=$(find "$TARGET_UPLOADS" -type f | wc -l | tr -d ' ')
log "done: $(jq -r '.counts.colonies' "$p/manifest.json") colonies, $(jq -r '.counts.colony_events' "$p/manifest.json") events, $files files restored from $1"
