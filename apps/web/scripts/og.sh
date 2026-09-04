#!/bin/bash
# Renders scripts/og.html to public/og.png (1200x630 at 2x).
set -euo pipefail
cd "$(dirname "$0")/.."
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1200,630 \
  --virtual-time-budget=4000 \
  --screenshot=public/og.png "file://$PWD/scripts/og.html" 2>/dev/null
magick public/og.png -resize 1200x630 public/og.png
echo "public/og.png $(magick identify -format '%wx%h %b' public/og.png)"
