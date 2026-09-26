# syntax=docker/dockerfile:1
# Backup/restore helper. Based on the official PostgreSQL image so that
# pg_dump/pg_restore always match the server version exactly.
FROM postgres:18-alpine
RUN apk add --no-cache rsync zstd supercronic coreutils findutils tzdata jq \
 && mkdir -p /app /data/backups /data/uploads
COPY --chmod=0755 backup.sh restore.sh healthcheck.sh entrypoint.sh /app/
ENV BACKUP_DIR=/data/backups UPLOADS_DIR=/data/uploads
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["cron"]
