#!/bin/bash
# Builds build/Corral-<version>.dmg from the app bundle.
#
# A DMG rather than a zip because that is what a Mac user expects to double
# click: the window opens with the app on the left and an Applications alias on
# the right, and installing is one drag. A zip leaves them holding a bundle in
# ~/Downloads wondering where to put it.
set -euo pipefail

cd "$(dirname "$0")/.."

# One source of truth for the base version. CI appends the run number to it;
# a local build just uses it as-is.
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"
APP_NAME="Corral"
APP="build/$APP_NAME.app"
DMG="build/$APP_NAME-$VERSION.dmg"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "✗ $APP not found — run ./scripts/make_app.sh first"; exit 1; }

echo "Staging $DMG..."
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

# ditto, not cp: it preserves the bundle's extended attributes and the code
# signature along with them. `cp -R` can strip them and leave an app macOS
# refuses to open.
ditto "$APP" "$STAGE/$APP_NAME.app"

# The drag target. A relative symlink would break once the image is mounted
# somewhere else, so this is the absolute path — which is the same on every Mac.
ln -s /Applications "$STAGE/Applications"

# A short volume name keeps the mounted disk's title readable in the Finder
# sidebar; UDZO is the compressed, read-only format every macOS can mount.
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo "Done: $DMG ($SIZE)"

# Prove the image mounts and carries a launchable app, rather than finding out
# from the first person who downloads it.
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT

if [ ! -x "$MOUNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]; then
    echo "✗ the DMG does not contain a launchable $APP_NAME.app"
    exit 1
fi
"$MOUNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" --version
echo "✓ verified: mounts, and the app inside runs"
