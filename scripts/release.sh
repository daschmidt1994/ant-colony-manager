#!/usr/bin/env sh
# Neue Version veröffentlichen:  ./scripts/release.sh 1.2.0
#   Version in app/pubspec.yaml setzen → Commit → Tag v1.2.0 → pushen.
#   Der Tag baut in der CI die Server-Images (1.2.0, 1.2, latest), das
#   GitHub-Release "v1.2.0" mit den APKs und das Update im F-Droid-Repo.
# SemVer: 1.1.1 Fehlerbehebung · 1.2.0 neue Funktion · 2.0.0 alte App und neuer
# Server (oder umgekehrt) passen nicht mehr zusammen.
# Steht die Version schon in pubspec.yaml, fehlt aber der Tag, wird nur getaggt.
# shellcheck disable=SC2034 # read by lib.sh
ACM_NO_COMPOSE=1
. "$(dirname -- "$0")/lib.sh"

NEW=${1:-}
PUBSPEC=app/pubspec.yaml
echo "$NEW" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "Aufruf: ./scripts/release.sh <x.y.z>  (z. B. 1.2.0)"
CUR=$(sed -nE 's/^version: *([^+ ]+).*/\1/p' "$PUBSPEC")
[ -n "$CUR" ] || die "keine Version in $PUBSPEC gefunden"

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "Releases nur von main"
git diff --quiet && git diff --cached --quiet || die "Arbeitsverzeichnis nicht sauber – erst committen"
git fetch --quiet --tags origin
git merge-base --is-ancestor origin/main HEAD || die "main ist nicht aktuell – erst: git pull --ff-only"
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null || [ -n "$(git ls-remote --tags origin "refs/tags/v$NEW")" ]; then
  die "Tag v$NEW gibt es schon"
fi
if [ "$NEW" != "$CUR" ]; then
  [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | tail -1)" = "$NEW" ] || die "$NEW ist nicht neuer als $CUR"
fi

say "Release v$NEW (bisher $CUR) von $(git rev-parse --short HEAD)"
git log --oneline "$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || git rev-list --max-parents=0 HEAD)..HEAD" | sed 's/^/  /'
printf 'Version setzen, taggen und pushen? [j/N] '
read -r ok
case "$ok" in j|J|y|Y) ;; *) die "abgebrochen" ;; esac

if [ "$NEW" != "$CUR" ]; then
  tmp=$(mktemp)
  sed -E "s/^version: *[^+ ]+/version: $NEW/" "$PUBSPEC" > "$tmp" && cat "$tmp" > "$PUBSPEC" && rm -f "$tmp"
  git commit --quiet -m "Version $NEW" -- "$PUBSPEC"
fi
git tag -a "v$NEW" -m "Version $NEW"
git push --atomic origin main "v$NEW"
say "v$NEW ist unterwegs – Fortschritt: gh run list (Images, App), danach: gh release view v$NEW"
