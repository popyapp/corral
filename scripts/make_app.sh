#!/bin/bash
# Builds Corral.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."

# CI passes VERSION in (the base in ./VERSION plus the run number), and that is
# the released number. A local build has no run number, and reporting the bare
# base — "0.1" — tells you nothing about what you are actually running. Git
# already knows: the last release tag, plus how far past it this tree is.
if [ -z "${VERSION:-}" ]; then
    TAG="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
    if [ -n "$TAG" ]; then
        AHEAD="$(git rev-list --count "$TAG"..HEAD 2>/dev/null || echo 0)"
        # "+3" is semver's build-metadata separator, which is exactly what this
        # is: the 0.1.5 release, plus three commits.
        [ "$AHEAD" -gt 0 ] && VERSION="${TAG#v}+$AHEAD" || VERSION="${TAG#v}"
    else
        # No tags fetched (a shallow clone, or a fork that has never released).
        VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
    fi
fi
# A binary built from a tree with uncommitted changes corresponds to no commit,
# and the About panel says so rather than naming a commit it does not match.
# CI checks out clean, and passes COMMIT in anyway, so this only fires locally.
if [ -z "${COMMIT:-}" ]; then
    COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ "$COMMIT" != "unknown" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        COMMIT="$COMMIT-dirty"
    fi
fi
APP_NAME="Corral"
# Reverse-DNS of the organisation the Developer ID certificate is issued to.
# It is also the domain the app's settings live under, so changing it again
# would silently reset everyone's preferences.
BUNDLE_ID="com.scaleyazilim.corral"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

# Both architectures, in one binary.
#
# Not a nicety: a thin arm64 build cannot start at all on an Intel Mac, and
# nothing about a downloaded DMG warns you before you try. Shipping one file
# that runs everywhere is cheaper than explaining which file to take.
ARCHS=(--arch arm64 --arch x86_64)

echo "Building release binary (arm64 + x86_64)..."
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
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
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# Ad hoc by default, which is a working app that Gatekeeper will refuse until
# somebody right-clicks it. Releases pass a real identity:
#
#   CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./scripts/make_app.sh
IDENTITY="${CODESIGN_IDENTITY:--}"

# The hardened runtime is what notarisation requires, and Corral needs no
# exception to it — no JIT, no unsigned executable memory, no DYLD overrides,
# and not one entitlement. Everything it reads is readable by any process
# running as you. It is applied to ad-hoc builds too, so a local build behaves
# the way the shipped one does rather than differing in the one respect that
# tends to break only after release.
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")

if [ "$IDENTITY" = "-" ]; then
    echo "Signing (ad hoc, hardened runtime)..."
    # A secure timestamp needs Apple's server and an identity it recognises;
    # asking for one ad hoc just fails.
    SIGN_ARGS+=(--timestamp=none)
else
    echo "Signing with identity: $IDENTITY"
    # Notarisation rejects anything without one.
    SIGN_ARGS+=(--timestamp)
fi

# No nested code in the bundle, so --deep (deprecated) buys nothing.
codesign "${SIGN_ARGS[@]}" "$APP"

echo "Done: $APP"
codesign -dv "$APP" 2>&1 | grep -E '^(CDHash|Authority|Signature|Runtime)' || true
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

