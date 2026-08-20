#!/bin/bash
# Builds Corral.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
COMMIT="${COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
APP_NAME="Corral"
BUNDLE_ID="dev.kulekci.Corral"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

echo "Building release binary..."
swift build -c release

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>GitCommitHash</key>
    <string>$COMMIT</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# Ad hoc by default. Corral needs no entitlements and no privacy grants — every
# fact it reads is available to any process running as you — so an ad-hoc build
# is perfectly usable. Sign with a real identity if you want Gatekeeper to stop
# asking:
#
#   CODESIGN_IDENTITY="Apple Development: you (TEAMID)" ./scripts/make_app.sh
IDENTITY="${CODESIGN_IDENTITY:--}"

if [ "$IDENTITY" = "-" ]; then
    echo "Signing (ad hoc)..."
else
    echo "Signing with identity: $IDENTITY"
fi
# No nested code in the bundle, so --deep (deprecated) buys nothing.
codesign --force --sign "$IDENTITY" "$APP"

echo "Done: $APP"
codesign -dv "$APP" 2>&1 | grep -E '^(CDHash|Authority|Signature)' || true

