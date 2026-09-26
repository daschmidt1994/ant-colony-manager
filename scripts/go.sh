#!/usr/bin/env sh
# Runs the Go toolchain in a container (no local Go installation needed).
# Usage: scripts/go.sh go test ./...
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec docker run --rm \
  -v "$ROOT":/src -w /src/server \
  -v acm-gomod:/go/pkg/mod -v acm-gobuild:/root/.cache/go-build \
  --network host \
  -e TEST_DATABASE_URL -e TEST_VERBOSE_LOG -e GOFLAGS -e CGO_ENABLED=0 \
  golang:1.26-alpine "$@"
