#!/bin/bash
# Builds SelectBar.app and signs it.
#
# The signature matters not for security but for permissions: macOS ties the
# granted access to the app's signature. Without one, access would have to be
# granted again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="SelectBar.app"
# The bundle is staged in a temporary folder outside the Desktop: it syncs with
# iCloud, and the file provider stamps files with com.apple.FinderInfo and
# com.apple.fileprovider attributes, which codesign rejects and which come
# straight back if cleaned in place.
PROJECT="$(pwd)"
STAGE="$(mktemp -d /tmp/selectbar-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
BIN="$STAGE/$APP/Contents/MacOS/SelectBar"

echo "==> building"
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"
# main.swift must come last: Swift looks for the entry point there.
swiftc -O -o "$BIN" \
    $(ls Sources/*.swift | grep -v 'main\.swift$') Sources/main.swift \
    -framework AppKit -framework ApplicationServices \
    -framework Metal -framework ScreenCaptureKit
cp Info.plist "$STAGE/$APP/Contents/Info.plist"

if [ -d AppIcon.iconset ]; then
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$STAGE/$APP" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | awk 'NR==1 && /\)/ {print $2}')
if [ -n "${IDENTITY:-}" ]; then
    echo "==> signing ($IDENTITY)"
    codesign --force --sign "$IDENTITY" "$STAGE/$APP"
else
    echo "==> ad-hoc signing (no persistent identity found)"
    codesign --force --sign - "$STAGE/$APP"
fi

# Checked by exit code rather than by the last command in a pipeline:
# otherwise a failed signature goes unnoticed.
if codesign --verify --strict "$STAGE/$APP" 2>/tmp/selectbar-codesign.txt; then
    echo "==> signature is valid"
else
    echo "ERROR: the signature failed verification" >&2
    cat /tmp/selectbar-codesign.txt >&2
    exit 1
fi

echo "==> installing"
rm -rf "$PROJECT/$APP" "/Applications/$APP"
ditto "$STAGE/$APP" "$PROJECT/$APP"
ditto "$STAGE/$APP" "/Applications/$APP"

echo "Done: /Applications/$APP"
echo "Run with: open /Applications/$APP"
