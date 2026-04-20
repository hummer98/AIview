#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
SRC="${REPO_ROOT}/design/appicon-master.svg"
OUT="${REPO_ROOT}/AIview/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$SRC" ]]; then
  echo "error: master SVG not found: $SRC" >&2
  exit 1
fi

mkdir -p "$OUT"

if command -v rsvg-convert >/dev/null 2>&1; then
  RENDERER="rsvg"
elif command -v magick >/dev/null 2>&1; then
  RENDERER="magick"
elif command -v convert >/dev/null 2>&1; then
  RENDERER="convert"
else
  echo "error: neither rsvg-convert nor ImageMagick (magick/convert) found." >&2
  echo "  install one of:" >&2
  echo "    brew install librsvg     # recommended" >&2
  echo "    brew install imagemagick # fallback" >&2
  exit 1
fi

render() { # $1=size $2=filename
  local size="$1"
  local name="$2"
  case "$RENDERER" in
    rsvg)
      rsvg-convert -w "$size" -h "$size" "$SRC" -o "$OUT/$name"
      ;;
    magick)
      magick -density 2048 -background none "$SRC" -resize "${size}x${size}" "$OUT/$name"
      ;;
    convert)
      convert -density 2048 -background none "$SRC" -resize "${size}x${size}" "$OUT/$name"
      ;;
  esac
}

render 16   icon_16.png
render 32   icon_16@2x.png
render 32   icon_32.png
render 64   icon_32@2x.png
render 128  icon_128.png
render 256  icon_128@2x.png
render 256  icon_256.png
render 512  icon_256@2x.png
render 512  icon_512.png
render 1024 icon_512@2x.png

echo "generated 10 PNGs in $OUT (renderer: $RENDERER)"
