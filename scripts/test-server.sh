#!/usr/bin/env sh
# Runs all backend tests against a throw-away PostgreSQL 18 (in RAM).
# Usage: scripts/test-server.sh [go test args…]   e.g. -run TestSync -v
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NAME=acm-test-db
PORT=${TEST_DB_PORT:-55432}

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:5432" \
  -e POSTGRES_PASSWORD=test --tmpfs /var/lib/postgresql:rw \
  postgres:18-alpine -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c max_connections=300 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

i=0
until docker exec "$NAME" pg_isready -U postgres -q 2>/dev/null; do
  i=$((i+1)); [ "$i" -gt 60 ] && { echo "database did not start" >&2; exit 1; }
  sleep 1
done
sleep 1

export TEST_DATABASE_URL="postgres://postgres:test@127.0.0.1:$PORT/postgres?sslmode=disable"
"$ROOT/scripts/go.sh" go test -count=1 -p 1 "$@" ./...
