#!/usr/bin/env bash
# Adds the freshly built APKs to the F-Droid repo on the gh-pages branch
# (GitHub Pages: https://<owner>.github.io/<repo>/fdroid/repo). Run by the App
# workflow for a version tag (v1.2.3, PKG=at.antcolony.manager) and for main
# (test app, PKG=at.antcolony.manager.dev). Needs FDROID_KEYSTORE_BASE64/_PASS,
# GH_TOKEN, RUN (build number) and fdroidserver on PATH.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEP=3 # builds kept per app (F-Droid can then also roll back)
PKG=${PKG:-at.antcolony.manager}
[ -f "$ROOT/fdroid/metadata/$PKG.yml" ] || { echo "no metadata for $PKG" >&2; exit 1; }
if [ -z "${FDROID_KEYSTORE_BASE64:-}" ]; then echo "no F-Droid keystore secret – skipping"; exit 0; fi

URL=${FDROID_PAGES_REMOTE:-"https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"}
APKS=${APK_DIR:-"$ROOT/app/build/app/outputs/flutter-apk"}

# One attempt (own process, so set -e applies): fresh clone of gh-pages, add the APKs, re-sign the index, push.
# The app and the test app publish independently; a rejected push (the other
# one was faster) is retried on top of the new state.
publish() {
  rm -rf "$W/site" "$W/work"
  command -v rsync >/dev/null || { echo "rsync missing" >&2; exit 1; }
  if git ls-remote --exit-code --heads "$URL" gh-pages >/dev/null; then
    git clone --quiet --depth 1 --branch gh-pages "$URL" "$W/site"
  else
    git init --quiet -b gh-pages "$W/site" && git -C "$W/site" remote add origin "$URL"
  fi

  # Work outside the published tree: config and keystore never land on gh-pages.
  mkdir -p "$W/work/repo" "$W/site/fdroid/repo"
  cp -r "$ROOT/fdroid/metadata" "$ROOT/fdroid/icon.png" "$W/work/"
  { cat "$ROOT/fdroid/config.yml"; echo "sdk_path: ${ANDROID_HOME:-$ANDROID_SDK_ROOT}"; } > "$W/work/config.yml"
  chmod 600 "$W/work/config.yml"
  cp "$W/keystore.p12" "$W/work/keystore.p12"
  cp -a "$W/site/fdroid/repo/." "$W/work/repo/"

  for apk in "$APKS"/app-*-release.apk; do
    abi=$(basename "$apk" | sed -E 's/^app-(.*)-release\.apk$/\1/')
    cp "$apk" "$W/work/repo/${PKG}_${RUN}_${abi}.apk"
  done
  # Keep the newest $KEEP builds of this app ("${PKG}_" never matches the other app).
  ls "$W/work/repo" | sed -nE "s/^${PKG//./\\.}_([0-9]+)_.*\.apk$/\1/p" | sort -un | head -n -"$KEEP" \
    | while read -r old; do rm -f "$W/work/repo/${PKG}_${old}_"*.apk; done

  (cd "$W/work" && fdroid update --use-date-from-apk)

  rsync -a --delete "$W/work/repo/" "$W/site/fdroid/repo/"
  touch "$W/site/.nojekyll"
  git -C "$W/site" add -A
  git -C "$W/site" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "F-Droid-Repo: $PKG Build $RUN"
  git -C "$W/site" push --quiet origin gh-pages
}

if [ "${1:-}" = --attempt ]; then
  publish
  exit 0
fi

W=$(mktemp -d)
export W
trap 'rm -rf "$W"' EXIT
echo "$FDROID_KEYSTORE_BASE64" | base64 -d > "$W/keystore.p12"
for attempt in 1 2 3; do
  "$0" --attempt && break
  [ "$attempt" = 3 ] && { echo "F-Droid repo: publishing failed 3 times" >&2; exit 1; }
  echo "attempt failed – retrying on the new state ($attempt/3)"
  sleep $((attempt * 10))
done
echo "F-Droid repo updated ($PKG): https://${GITHUB_REPOSITORY_OWNER}.github.io/${GITHUB_REPOSITORY#*/}/fdroid/repo"
