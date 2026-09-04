#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/cctray.app
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

FLAGS=(-c release)

BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"
swift build "${FLAGS[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/cctray" "$APP/Contents/MacOS/cctray"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

identity() {
    security find-identity -v -p codesigning \
        | awk -F'"' -v pat="$1" '$0 ~ pat { print $2; exit }'
}

ID="${CODESIGN_IDENTITY:-$(identity "Developer ID Application")}"
if [ -n "$ID" ]; then
    codesign --force --timestamp --options runtime \
             --entitlements cctray.entitlements --sign "$ID" "$APP"
    echo "Signed for distribution: $ID"
else
    ID="$(identity "Apple Development")"
    codesign --force --sign "${ID:--}" "$APP"
    echo "No Developer ID cert. Signed '${ID:-ad-hoc}'; this build runs on this Mac only."
fi

codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD)"
