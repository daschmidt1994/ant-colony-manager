#!/bin/sh
# Update service (optional, COMPOSE_PROFILES=updater): carries out an update
# that an administrator starts in the app (Mehr → Server → „Jetzt
# aktualisieren“). The app only drops a request file into /data/update – it
# never talks to Docker itself. Steps: pull the images (does not disturb the
# running stack), and only if one of them is newer: backup, restart, wait
# until healthy. Without a newer image nothing else happens. Needs the Docker
# socket and the project folder at the same path as on the host
# (ACM_PROJECT_DIR).
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

# newer: prints the services whose pulled image differs from the running one
newer() {
  for svc in "$@"; do
    id=$(docker compose ps -q "$svc" | head -1)
    [ -n "$id" ] || continue
    running=$(docker inspect -f '{{.Image}}' "$id")
    ref=$(docker inspect -f '{{.Config.Image}}' "$id")
    latest=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)
    [ -n "$latest" ] && [ "$latest" != "$running" ] && echo "$svc"
  done
  return 0
}

update() {
  echo "== $(date) Update angefordert"
  list=$(services)
  status running "Suche nach neuen Images …"
  # shellcheck disable=SC2086 # one service per word
  docker compose pull --ignore-buildable --quiet $list || return 1
  # shellcheck disable=SC2086
  changed=$(newer $list)
  if [ -z "$changed" ]; then
    echo "Alle Images sind aktuell – kein Backup, kein Neustart."
    return 3
  fi
  echo "Neue Images für: $(echo "$changed" | tr '\n' ' ')"
  status running "Backup vor dem Update …"
  docker compose exec -T backup /app/entrypoint.sh backup --tag pre-update || echo "Backup fehlgeschlagen – fahre fort"
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
    update > "$dir/update.log" 2>&1
    case $? in
      0) status "done" "Update abgeschlossen" ;;
      3) status current "Bereits aktuell – kein Update nötig" ;;
      *) status failed "Update fehlgeschlagen – Protokoll: data/update/update.log; zurück: ./scripts/restore.sh <pre-update-Backup>" ;;
    esac
    docker image prune -f > /dev/null 2>&1 || true
  fi
  sleep 5
done
