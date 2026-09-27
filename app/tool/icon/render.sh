#!/usr/bin/env sh
# Renders tool/icon/ant.svg to every app icon (Android legacy + adaptive,
# web, F-Droid). Needs ImageMagick with librsvg. Run from app/: tool/icon/render.sh
set -eu
cd "$(dirname "$0")/../.."
BG='#111315'
ANT=$(sed -n '/<g id="ant"/,/<\/g>/p' tool/icon/ant.svg)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# variant <name> <background-svg> <scale>
variant() {
  printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">%s<g transform="translate(256 256) scale(%s) translate(-256 -256)">%s</g></svg>' \
    "$2" "$3" "$ANT" > "$T/$1.svg"
}
variant rounded "<rect width=\"512\" height=\"512\" rx=\"112\" fill=\"$BG\"/>" 0.86   # launchers without adaptive icons, web, F-Droid
variant full "<rect width=\"512\" height=\"512\" fill=\"$BG\"/>" 0.62                # web maskable: the OS cuts the shape
variant fg "" 0.62                                                                     # Android adaptive foreground (safe zone 66/108)

png() { magick -background none -density 384 "$T/$1.svg" -resize "$2x$2" "PNG32:$3"; }

RES=android/app/src/main/res
for d in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r dens legacy adaptive <<EOT
$d
EOT
  png rounded "$legacy" "$RES/mipmap-$dens/ic_launcher.png"
  png fg "$adaptive" "$RES/mipmap-$dens/ic_launcher_foreground.png"
done
png rounded 192 web/icons/Icon-192.png
png rounded 512 web/icons/Icon-512.png
png full 192 web/icons/Icon-maskable-192.png
png full 512 web/icons/Icon-maskable-512.png
png rounded 32 web/favicon.png
png rounded 512 ../fdroid/icon.png
png fg 256 assets/icon/ant.png # in-app logo (login, navigation)
echo "icons written"
