#!/bin/bash
# Prints the release notes for a built artefact to stdout.
#
#   VERSION=0.1.16 COMMIT=abc1234 ./scripts/release_notes.sh
#
# Lifted out of the workflow so it can be run against a real build and read
# before anyone publishes it. It was six lines of YAML-quoted shell that only
# ever executed on a runner, and the paragraph it writes is the only
# instruction most people downloading this will read.
#
# BUILD_DIR defaults to build/ — the staple job points it somewhere else.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION is required}"
COMMIT="${COMMIT:?COMMIT is required}"
BUILD_DIR="${BUILD_DIR:-build}"
APP="$BUILD_DIR/Corral.app"

SERVER="${GITHUB_SERVER_URL:-https://github.com}"
REPO="${GITHUB_REPOSITORY:-popyapp/corral}"
SHA="${GITHUB_SHA:-$COMMIT}"

echo "**Version:** \`$VERSION\` · **Build commit:** [\`$COMMIT\`]($SERVER/$REPO/commit/$SHA)"
echo ""
echo "| Download | SHA-256 |"
echo "|---|---|"
echo "| \`Corral-$VERSION.dmg\` | \`$(cut -d' ' -f1 "$BUILD_DIR/Corral-$VERSION.dmg.sha256")\` |"
echo "| \`Corral-$VERSION.zip\` | \`$(cut -d' ' -f1 "$BUILD_DIR/Corral-$VERSION.zip.sha256")\` |"
echo ""
echo "### Installing"
echo ""
echo "Open the DMG and drag **Corral** to Applications."
echo ""

# Read once into a variable rather than tested through a pipe. `codesign |
# grep -q` looks obvious and is wrong under `pipefail`: grep closes the pipe
# the moment it matches, codesign dies of SIGPIPE, and the pipeline reports
# that failure — so the condition is false precisely when the match succeeded.
# It survived in the workflow only because a `run:` step has -e but not
# pipefail, and it inverted the moment the same line moved into this file.
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"

# What the person downloading this will actually meet, decided by looking
# rather than by assuming. There are three states, not two, and calling a
# Developer ID build ad-hoc is as wrong as the reverse.
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "Signed and notarised by Apple, so it opens on a double click."
    echo "Universal: Apple Silicon and Intel."
elif [[ "$SIGNATURE" == *"Authority=Developer ID"* ]]; then
    echo "Signed with a Developer ID and the hardened runtime, but Apple's"
    echo "notary service had not answered by the time the build stopped"
    echo "waiting, so no ticket is stapled into it. macOS checks with Apple"
    echo "at first launch; if it asks anyway, use **right-click → Open**."
    echo "Universal: Apple Silicon and Intel."
else
    echo "This build is signed ad hoc rather than notarised, so the first"
    echo "launch needs **right-click → Open** (or **System Settings →"
    echo "Privacy & Security → Open Anyway**)."
fi

# Set by the staple job. Replacing the files under a release that people have
# already downloaded is worth a sentence: the checksums above are not the ones
# that were published first, and someone comparing them deserves to know why
# rather than concluding the download was tampered with.
if [ -n "${STAPLED_LATER:-}" ]; then
    echo ""
    echo "_Apple's ticket arrived after this release was first published. The"
    echo "downloads and checksums above were replaced with stapled ones on"
    echo "$STAPLED_LATER; the binary inside is the same build._"
fi

echo ""
echo "Verify what you downloaded against the checksum above, and"
echo "\`Corral --version\` prints the commit it was built from."
echo ""
cat .github/release-notes-footer.md
