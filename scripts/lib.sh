# Shared helpers for the operator scripts (sourced, not executed).
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mFehler: %s\033[0m\n' "$*" >&2; exit 1; }

# init-env.sh only writes .env – it also works where compose runs elsewhere
# (Unraid with Dockhand/Portainer, Synology Container Manager …).
if [ -z "${ACM_NO_COMPOSE:-}" ]; then
  command -v docker >/dev/null || die "docker ist nicht installiert"
  docker compose version >/dev/null 2>&1 || die "docker compose (v2) ist nicht installiert"
fi

dc() { docker compose "$@"; }

require_env() { [ -f .env ] || die ".env fehlt – zuerst: cp .env.example .env (oder ./scripts/init-env.sh)"; }

# Absolute host path of a service volume, as resolved by compose.
volume_source() { # service target
  dc config --format json | jq -r --arg s "$1" --arg t "$2" '.services[$s].volumes[] | select(.target == $t) | .source'
}

container_health() { # service
  id=$(dc ps -q "$1" 2>/dev/null | head -1)
  [ -n "$id" ] || { echo missing; return; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id"
}

wait_healthy() { # service [timeout seconds]
  t=${2:-180}; i=0
  while [ "$i" -lt "$t" ]; do
    case "$(container_health "$1")" in
      healthy) return 0 ;;
      unhealthy) break ;;
    esac
    sleep 2; i=$((i+2))
  done
  dc ps
  dc logs --tail 40 "$1" >&2
  die "$1 ist nicht healthy geworden"
}

backup_running() { [ "$(container_health backup)" = healthy ] || [ "$(container_health backup)" = starting ]; }

run_backup_tool() { # args…
  if backup_running; then
    dc exec -T backup /app/entrypoint.sh "$@"
  else
    dc run --rm --no-deps -T backup "$@"
  fi
}
