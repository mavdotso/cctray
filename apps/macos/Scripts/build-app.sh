#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/cctray.app
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

FLAGS=(-c release)
STEPS=4
TTY=0
[ -t 1 ] && TTY=1
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

bold() { [ "$TTY" = 1 ] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }

FRAMES=('|' '/' '-' '\')
FULL='===================='
EMPTY='....................'

# SwiftPM prints nothing between "Building for production..." and the first compiled file.
step() {
    local n=$1 label=$2; shift 2
    printf '%s %s\n' "$(bold "[$n/$STEPS]")" "$label"
    if [ "$TTY" != 1 ]; then "$@"; return; fi
    : >"$LOG"
    "$@" >"$LOG" 2>&1 &
    local pid=$! start=$SECONDS i=0 status=0 width=20 filled=0 last
    while kill -0 "$pid" 2>/dev/null; do
        last=$(tail -n1 "$LOG" 2>/dev/null || true)
        if [[ $last =~ \[([0-9]+)/([0-9]+)\] ]] && (( BASH_REMATCH[2] > 0 )); then
            filled=$(( BASH_REMATCH[1] * width / BASH_REMATCH[2] ))
            (( filled > width )) && filled=$width
        fi
        printf '\r\033[K  %s [%s%s] %3ds' "${FRAMES[i++ % 4]}" \
            "${FULL:0:filled}" "${EMPTY:0:width-filled}" "$((SECONDS - start))"
        sleep 0.2
    done
    wait "$pid" || status=$?
    printf '\r\033[K'
    if [ "$status" -ne 0 ]; then cat "$LOG"; return "$status"; fi
    printf '  done in %ss\n' "$((SECONDS - start))"
}

[ -d .build ] || echo "First build on this Mac. It can take several minutes; later builds take seconds."

step 1 "Compiling" swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

assemble() {
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN/cctray" "$APP/Contents/MacOS/cctray"
    cp Info.plist "$APP/Contents/Info.plist"
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
}
step 2 "Assembling $APP" assemble

identity() {
    security find-identity -v -p codesigning \
        | awk -F'"' -v pat="$1" '$0 ~ pat { print $2; exit }'
}

ID="${CODESIGN_IDENTITY:-$(identity "Developer ID Application")}"
if [ -n "$ID" ]; then
    step 3 "Signing for distribution" \
        codesign --force --timestamp --options runtime \
                 --entitlements cctray.entitlements --sign "$ID" "$APP"
    echo "  identity: $ID"
else
    ID="$(identity "Apple Development")"
    step 3 "Signing" codesign --force --sign "${ID:--}" "$APP"
    echo "  No Developer ID cert. Signed '${ID:-ad-hoc}'; this build runs on this Mac only."
fi

step 4 "Verifying" codesign --verify --strict "$APP"
printf '%s %s (%s build %s)\n' "$(bold "Built")" "$APP" "$VERSION" "$BUILD"
