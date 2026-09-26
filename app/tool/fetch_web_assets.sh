#!/usr/bin/env sh
# Downloads sqlite3.wasm matching the sqlite3 package version in pubspec.lock
# into web/ (needed for the local database of the web app).
set -eu
cd "$(dirname "$0")/.."
version=$(awk '/^  sqlite3:/{f=1} f && /version:/{gsub(/"/,"",$2); print $2; exit}' pubspec.lock)
[ -n "$version" ] || { echo "sqlite3 version not found in pubspec.lock" >&2; exit 1; }
url="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$version/sqlite3.wasm"
echo "fetching $url"
curl -fsSL -o web/sqlite3.wasm "$url"
ls -l web/sqlite3.wasm
