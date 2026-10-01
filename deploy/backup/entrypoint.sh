#!/bin/sh
# cron (default)      – run scheduled backups via supercronic
# backup [--tag X]    – one backup now
# list | verify <dir> – see backup.sh
# restore <dir>       – see restore.sh (use scripts/restore.sh on the host)
# init-dirs           – create data directories with the right owner (runs as root)
set -eu
# The database password may come from the generated secrets file.
if [ -z "${PGPASSWORD:-}" ] && [ -r /data/secrets/postgres_password ]; then
  PGPASSWORD=$(cat /data/secrets/postgres_password); export PGPASSWORD
fi
case "${1:-cron}" in
  cron)
    date +%s > /tmp/started
    echo "${BACKUP_SCHEDULE:-0 3 * * *} /app/backup.sh" > /tmp/crontab
    echo "backup: schedule '${BACKUP_SCHEDULE:-0 3 * * *}', keeping ${BACKUP_KEEP_DAILY:-7} daily / ${BACKUP_KEEP_WEEKLY:-4} weekly / ${BACKUP_KEEP_MONTHLY:-6} monthly"
    exec supercronic -quiet /tmp/crontab ;;
  init-dirs)
    uid=${PUID:-1000}; gid=${PGID:-1000}
    mkdir -p /data/uploads /data/backups /data/secrets
    # Only fix ownership of our own directories, never touch postgres data.
    chown "$uid:$gid" /data/uploads /data/backups
    [ -z "$(find /data/uploads -maxdepth 3 ! -user "$uid" -print -quit)" ] || chown -R "$uid:$gid" /data/uploads
    # Secrets: values from .env win; otherwise generate once and keep.
    chown "root:$gid" /data/secrets && chmod 0750 /data/secrets
    secret() { # file, env value, owner
      f="/data/secrets/$1"
      if [ -n "$2" ]; then printf '%s' "$2" > "$f.tmp" && mv "$f.tmp" "$f"
      elif [ ! -s "$f" ]; then
        head -c 48 /dev/urandom | base64 | tr -d '\n/+=' > "$f"
        echo "generated secret $1"
      fi
      chown "$3" "$f" && chmod 0440 "$f"
    }
    # postgres (uid 70 in the alpine image) reads its password after dropping root
    secret postgres_password "${POSTGRES_PASSWORD:-}" "70:$gid"
    secret jwt_secret "${JWT_SECRET:-}" "$uid:$gid"
    secret instance_secret "${INSTANCE_SECRET:-}" "$uid:$gid"
    echo "data directories ready (owner $uid:$gid)" ;;
  backup) shift; exec /app/backup.sh "$@" ;;
  list|verify|prune) exec /app/backup.sh "$@" ;;
  restore) shift; exec /app/restore.sh "$@" ;;
  *) exec "$@" ;;
esac
