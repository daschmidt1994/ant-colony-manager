#!/bin/sh
# Ant Colony Manager backup tool (runs inside the backup container).
#
#   backup.sh [--tag NAME]     create a backup (default when called by cron)
#   backup.sh list             list backups
#   backup.sh verify NAME      full check: checksums + test restore into a temporary database
#   backup.sh prune            apply retention now
#
# Layout of one backup (a normal directory, usable without this tool):
#   <name>/db.dump          pg_dump custom format (zstd)
#   <name>/uploads/         photos; unchanged files are hard links to the previous backup
#   <name>/uploads.sha256   checksums of all files in uploads/
#   <name>/env.redacted     configuration with secrets removed (or env with BACKUP_INCLUDE_ENV=true)
#   <name>/manifest.json    versions, row counts, checksums
#   <name>/OK               written last – a backup without it is incomplete
set -eu
umask 077

BACKUP_DIR=${BACKUP_DIR:-/data/backups}
UPLOADS_DIR=${UPLOADS_DIR:-/data/uploads}
ENV_FILE=${ENV_FILE:-/config/.env}
KEEP_DAILY=${BACKUP_KEEP_DAILY:-7}
KEEP_WEEKLY=${BACKUP_KEEP_WEEKLY:-4}
KEEP_MONTHLY=${BACKUP_KEEP_MONTHLY:-6}
STATUS="$BACKUP_DIR/status.json"
COUNT_TABLES="users colonies colony_events feeding_items photos scan_links nfc_tags locations queens care_schedules"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') backup: $*"; }
die() { log "ERROR: $*"; exit 1; }

counts_json() { # $1 = database
  q="SELECT json_build_object("
  sep=""
  for t in $COUNT_TABLES; do
    q="$q$sep'$t', (SELECT count(*) FROM $t)"
    sep=", "
  done
  psql -X -d "$1" -Atc "$q)"
}

is_complete() { [ -f "$1/OK" ] && [ -f "$1/manifest.json" ]; }

# Names of backup directories (they always start with a date).
backup_names() { find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*' -printf '%f\n' 2>/dev/null | sort; }

latest_complete() {
  for d in $(backup_names | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}' | sort -r); do
    if is_complete "$BACKUP_DIR/$d"; then echo "$d"; return; fi
  done
}

write_status_ok() { # $1 name
  size=$(du -sb "$BACKUP_DIR/$1" | cut -f1)
  total=$(du -sb --exclude=.tmp-* "$BACKUP_DIR" | cut -f1)
  count=$(backup_names | grep -c . || true)
  jq -n --arg name "$1" --arg at "$(date -Iseconds)" --argjson size "$size" --argjson total "$total" \
     --argjson count "$count" \
     '{last_success: $at, last_name: $name, last_size_bytes: $size, total_bytes: $total, backups: $count, verified: "quick", last_error: null}' \
     > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

write_status_error() { # $1 message
  prev='{}'
  [ -f "$STATUS" ] && prev=$(cat "$STATUS")
  echo "$prev" | jq --arg err "$1" --arg at "$(date -Iseconds)" '. + {last_error: $err, last_error_at: $at}' \
     > "$STATUS.tmp" 2>/dev/null && mv "$STATUS.tmp" "$STATUS" || true
}

# ---------------------------------------------------------------------------

do_backup() {
  tag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) tag=$(echo "${2:-}" | tr -cd 'a-zA-Z0-9_-' | cut -c1-40); shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  mkdir -p "$BACKUP_DIR"
  lock="$BACKUP_DIR/.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +360 2>/dev/null)" ]; then
      log "removing stale lock"; rmdir "$lock"; mkdir "$lock"
    else
      die "another backup is running"
    fi
  fi
  name=$(date +%Y-%m-%dT%H%M)
  [ -n "$tag" ] && name="$name-$tag"
  [ -e "$BACKUP_DIR/$name" ] && name="$name$(date +%S)"
  tmp="$BACKUP_DIR/.tmp-$name"
  # shellcheck disable=SC2154 # rc is assigned inside the trap
  trap 'rc=$?; rm -rf "$tmp"; rmdir "$lock" 2>/dev/null; [ $rc -ne 0 ] && write_status_error "backup $name failed (exit $rc)"; exit $rc' EXIT
  mkdir -p "$tmp"
  log "starting $name"

  # 1. Database (consistent snapshot while the app keeps running)
  pg_dump --format=custom --compress=zstd:3 --file="$tmp/db.dump" "$PGDATABASE" || die "pg_dump failed"
  pg_restore --list "$tmp/db.dump" > /dev/null || die "dump is not readable"
  schema=$(psql -X -Atc "SELECT max(version) FROM schema_migrations")
  pgver=$(psql -X -Atc "SHOW server_version")
  counts=$(counts_json "$PGDATABASE")

  # 2. Uploads – incremental via hard links to the previous complete backup
  prev=$(latest_complete)
  mkdir -p "$tmp/uploads"
  if [ -d "$UPLOADS_DIR" ]; then
    if [ -n "$prev" ] && [ -d "$BACKUP_DIR/$prev/uploads" ]; then
      rsync -a --link-dest="$BACKUP_DIR/$prev/uploads/" "$UPLOADS_DIR/" "$tmp/uploads/"
    else
      rsync -a "$UPLOADS_DIR/" "$tmp/uploads/"
    fi
  fi
  # Checksums: reuse lines for hard-linked (unchanged) files, hash only new ones.
  (
    cd "$tmp"
    : > uploads.sha256.new
    find uploads -type f -links 1 -print0 | xargs -0 -r sha256sum >> uploads.sha256.new
    if [ -n "$prev" ] && [ -f "$BACKUP_DIR/$prev/uploads.sha256" ]; then
      find uploads -type f -links +1 | sort > linked.lst
      awk 'NR==FNR { keep["  " $0] = 1; next } { p = substr($0, 65) } (p in keep)' linked.lst "$BACKUP_DIR/$prev/uploads.sha256" >> uploads.sha256.new
      # hard-linked files missing from the previous list (should not happen) are hashed
      awk '{ print substr($0, 67) }' uploads.sha256.new | sort > have.lst
      comm -23 linked.lst have.lst | tr '\n' '\0' | xargs -0 -r sha256sum >> uploads.sha256.new
      rm -f linked.lst have.lst
    else
      find uploads -type f -links +1 -print0 | xargs -0 -r sha256sum >> uploads.sha256.new
    fi
    sort -k2 uploads.sha256.new > uploads.sha256 && rm uploads.sha256.new
  )
  files=$(wc -l < "$tmp/uploads.sha256" | tr -d ' ')
  upbytes=$(du -sb "$tmp/uploads" | cut -f1)

  # 3. Configuration
  if [ -r "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    if [ "${BACKUP_INCLUDE_ENV:-false}" = "true" ]; then
      cp "$ENV_FILE" "$tmp/env"
    else
      sed -E 's/^([A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|KEY)[A-Za-z0-9_]*)=.*/\1=***redacted***/' "$ENV_FILE" > "$tmp/env.redacted"
    fi
  fi

  # 4. Manifest
  dumpsha=$(sha256sum "$tmp/db.dump" | cut -d' ' -f1)
  dumpbytes=$(stat -c %s "$tmp/db.dump")
  jq -n --arg name "$name" --arg tag "$tag" --arg at "$(date -Iseconds)" --arg schema "$schema" --arg pg "$pgver" \
    --argjson counts "$counts" --arg dumpsha "$dumpsha" --argjson dumpbytes "$dumpbytes" \
    --argjson files "$files" --argjson upbytes "$upbytes" --arg prev "${prev:-}" \
    '{format: "acm-backup/1", name: $name, tag: (if $tag == "" then null else $tag end), created_at: $at,
      schema_version: $schema, postgres_version: $pg, counts: $counts,
      db_dump: {file: "db.dump", bytes: $dumpbytes, sha256: $dumpsha},
      uploads: {files: $files, bytes: $upbytes, checksums: "uploads.sha256", linked_to: (if $prev == "" then null else $prev end)}}' \
    > "$tmp/manifest.json"
  date -Iseconds > "$tmp/OK"
  mv "$tmp" "$BACKUP_DIR/$name"
  ln -sfn "$name" "$BACKUP_DIR/latest"
  log "done: $name (db $(numfmt --to=iec "$dumpbytes"), $files files, counts $counts)"
  [ -z "$tag" ] && do_prune
  write_status_ok "$name"
}

# Grandfather-father-son retention for automatic backups. Tagged (manual,
# pre-update, pre-restore) backups are never removed automatically.
do_prune() {
  auto=$(backup_names | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4,6}$' | sort -r) || true
  [ -z "$auto" ] && return 0
  latest=$(readlink "$BACKUP_DIR/latest" 2>/dev/null || true)
  keep=$(for n in $auto; do
      d=$(echo "$n" | cut -c1-10)
      echo "$n $d $(date -d "$d" +%G-W%V) $(echo "$n" | cut -c1-7)"
    done | awk -v kd="$KEEP_DAILY" -v kw="$KEEP_WEEKLY" -v km="$KEEP_MONTHLY" '
      { k = 0
        if (!($2 in D)) { D[$2] = 1; nd++; if (nd <= kd) k = 1 }
        if (!($3 in W)) { W[$3] = 1; nw++; if (nw <= kw) k = 1 }
        if (!($4 in M)) { M[$4] = 1; nm++; if (nm <= km) k = 1 }
        if (k) print $1 }')
  for n in $auto; do
    if ! echo "$keep" | grep -qx "$n" && [ "$n" != "$latest" ]; then
      log "retention: removing $n"
      rm -rf "${BACKUP_DIR:?}/$n"
    fi
  done
}

do_list() {
  printf '%-32s %-8s %10s %9s %8s %7s\n' NAME STATUS SIZE COLONIES EVENTS PHOTOS
  for d in $(backup_names); do
    p="$BACKUP_DIR/$d"
    if is_complete "$p"; then
      printf '%-32s %-8s %10s %9s %8s %7s\n' "$d" ok "$(du -sh "$p" | cut -f1)" \
        "$(jq -r .counts.colonies "$p/manifest.json")" "$(jq -r .counts.colony_events "$p/manifest.json")" \
        "$(jq -r .uploads.files "$p/manifest.json")"
    else
      printf '%-32s %-8s\n' "$d" INCOMPLETE
    fi
  done
}

# Full verification: checksums and a test restore into a temporary database.
do_verify() {
  name=${1:-$(readlink "$BACKUP_DIR/latest" 2>/dev/null || true)}
  [ -n "$name" ] || die "usage: verify NAME"
  p="$BACKUP_DIR/$(basename "$name")"
  is_complete "$p" || die "$name is incomplete or missing"
  log "verifying $name"
  echo "$(jq -r .db_dump.sha256 "$p/manifest.json")  $p/db.dump" | sha256sum -c --quiet || die "db.dump checksum mismatch"
  (cd "$p" && sha256sum -c --quiet uploads.sha256) || die "upload checksum mismatch"
  n=$(find "$p/uploads" -type f | wc -l | tr -d ' ')
  [ "$n" = "$(jq -r .uploads.files "$p/manifest.json")" ] || die "expected $(jq -r .uploads.files "$p/manifest.json") files, found $n"
  tmpdb="acm_verify_$$"
  createdb "$tmpdb"
  trap 'dropdb --if-exists "$tmpdb" >/dev/null 2>&1 || true' EXIT
  pg_restore --exit-on-error --no-owner --no-privileges -d "$tmpdb" "$p/db.dump" || die "test restore failed"
  got=$(counts_json "$tmpdb")
  want=$(jq -c .counts "$p/manifest.json")
  [ "$(echo "$got" | jq -S -c .)" = "$(echo "$want" | jq -S -c .)" ] || die "row counts differ: backup $want, restored $got"
  log "OK: $name – checksums valid, test restore successful ($got)"
}

case "${1:-backup}" in
  list) do_list ;;
  verify) shift; do_verify "${1:-}" ;;
  prune) do_prune ;;
  --tag|backup) [ "${1:-}" = backup ] && shift; do_backup "$@" ;;
  *) do_backup "$@" ;;
esac
