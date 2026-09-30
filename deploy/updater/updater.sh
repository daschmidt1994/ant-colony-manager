#!/bin/sh
# Update service (optional, COMPOSE_PROFILES=updater): carries out an update
# that an administrator starts in the app (Mehr → Version → „Jetzt
# aktualisieren“). The app only drops a request file into /data/update – it
# never talks to Docker itself. Steps like scripts/update.sh: backup, pull
# the images, restart, wait until healthy. Needs the Docker socket and the
# project folder at the same path as on the host (ACM_PROJECT_DIR).
set -u
dir=${UPDATE_DIR:-/data/update}
cd "${ACM_PROJECT_DIR:?ACM_PROJECT_DIR fehlt in .env}" || exit 1

status() { # state, message
  msg=$(printf '%s' "$2" | tr '"\\\n' "'/ ")
  printf '{"state":"%s","message":"%s","at":"%s"}\n' "$1" "$msg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/status.json.tmp" &&
    mv "$dir/status.json.tmp" "$dir/status.json"
}

# the running services except this one (the proxy only if it is on)
services() { docker compose ps --services --status running | grep -vx updater; }

healthy() { # service – waits up to 5 minutes
  i=0
  while [ "$i" -lt 150 ]; do
    id=$(docker compose ps -q "$1" | head -1)
    h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null)
    case "$h" in healthy|running) return 0 ;; unhealthy) return 1 ;; esac
    sleep 2; i=$((i+1))
  done
  return 1
}

update() {
  echo "== $(date) Update gestartet"
  status running "Backup vor dem Update …"
  docker compose exec -T backup /app/entrypoint.sh backup --tag pre-update || echo "Backup fehlgeschlagen – fahre fort"
  list=$(services)
  status running "Neue Images holen …"
  # shellcheck disable=SC2086 # one service per word
  docker compose pull --ignore-buildable --quiet $list || return 1
  status running "Neu starten …"
  # shellcheck disable=SC2086
  docker compose up -d --no-build $list || return 1
  status running "Warten, bis alles läuft …"
  healthy db && healthy app
}

[ -f "$dir/status.json" ] || status idle ""
echo "updater bereit (Projekt: $ACM_PROJECT_DIR)"
while :; do
  date -u +%s > "$dir/heartbeat"
  if [ -f "$dir/request" ]; then
    rm -f "$dir/request"
    if update > "$dir/update.log" 2>&1; then
      status "done" "Update abgeschlossen"
    else
      status failed "Update fehlgeschlagen – Protokoll: data/update/update.log; zurück: ./scripts/restore.sh <pre-update-Backup>"
    fi
    docker image prune -f > /dev/null 2>&1 || true
  fi
  sleep 5
done
