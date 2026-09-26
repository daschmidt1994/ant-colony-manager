#!/usr/bin/env sh
# Runs the Flutter toolchain in a container with a hard memory limit, so a
# large build can never push other services on the host out of memory.
# Usage: scripts/flutter.sh flutter test        (working dir: app/)
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:3.44.0}
MEM=${FLUTTER_MEMORY:-900m}
exec docker run --rm -i \
  --memory "$MEM" --memory-swap "$MEM" \
  -v "$ROOT":/src -w /src/app \
  -v acm-pub-cache:/root/.pub-cache \
  -e PUB_CACHE=/root/.pub-cache \
  -e ACM_TEST_SERVER \
  --network host \
  "$IMAGE" "$@"
