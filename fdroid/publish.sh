#!/usr/bin/env bash
# Adds the freshly built APKs to the F-Droid repo on the gh-pages branch
# (GitHub Pages: https://<owner>.github.io/<repo>/fdroid/repo). Run by the App
# workflow for a version tag (v1.2.3). Needs FDROID_KEYSTORE_BASE64/_PASS, GH_TOKEN,
# RUN (build number) and fdroidserver on PATH.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEP=3 # builds kept in the repo (F-Droid can then also roll back)
if [ -z "${FDROID_KEYSTORE_BASE64:-}" ]; then echo "no F-Droid keystore secret – skipping"; exit 0; fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
URL=${FDROID_PAGES_REMOTE:-"https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"}
APKS=${APK_DIR:-"$ROOT/app/build/app/outputs/flutter-apk"}
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
echo "$FDROID_KEYSTORE_BASE64" | base64 -d > "$W/work/keystore.p12"
cp -a "$W/site/fdroid/repo/." "$W/work/repo/"

for apk in "$APKS"/app-*-release.apk; do
  abi=$(basename "$apk" | sed -E 's/^app-(.*)-release\.apk$/\1/')
  cp "$apk" "$W/work/repo/at.antcolony.manager_${RUN}_${abi}.apk"
done
# Keep the newest $KEEP builds.
ls "$W/work/repo" | sed -nE 's/^at\.antcolony\.manager_([0-9]+)_.*\.apk$/\1/p' | sort -un | head -n -"$KEEP" \
  | while read -r old; do rm -f "$W/work/repo/at.antcolony.manager_${old}_"*.apk; done

(cd "$W/work" && fdroid update --use-date-from-apk)

rsync -a --delete "$W/work/repo/" "$W/site/fdroid/repo/"
touch "$W/site/.nojekyll"
cd "$W/site"
git add -A
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit --quiet -m "F-Droid-Repo: Build $RUN"
git push --quiet origin gh-pages
echo "F-Droid repo updated: https://${GITHUB_REPOSITORY_OWNER}.github.io/${GITHUB_REPOSITORY#*/}/fdroid/repo"
