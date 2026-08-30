#!/bin/bash
# Sends one artefact to Apple, waits for the verdict, and staples the ticket.
#
#   ./scripts/notarize.sh build/Corral.app
#   ./scripts/notarize.sh build/Corral-1.2.3.dmg
#
# Notarisation is not App Store review. Nobody looks at it: Apple scans the
# binary for malware and for the things a signature is supposed to guarantee,
# and answers in a few minutes. What it buys is the difference between an app
# that opens when double-clicked and one that has to be right-clicked past a
# warning saying it cannot be checked.
#
# Credentials come from the environment, as an App Store Connect API key rather
# than an Apple ID and password — a key has no second factor to get stuck on in
# CI, and can be revoked on its own:
#
#   AC_API_KEY_ID, AC_API_ISSUER_ID, AC_API_KEY_PATH (a .p8 file)
#
# With none of them set this exits successfully without doing anything, so a
# fork with no Apple account still gets a working build out of the same script.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "usage: $0 <path to .app or .dmg>"; exit 2; }
[ -e "$TARGET" ] || { echo "✗ $TARGET not found"; exit 1; }

if [ -z "${AC_API_KEY_ID:-}" ] || [ -z "${AC_API_ISSUER_ID:-}" ] || [ -z "${AC_API_KEY_PATH:-}" ]; then
    echo "⚠ no App Store Connect credentials — skipping notarisation of $TARGET"
    echo "  (the artefact is still signed; Gatekeeper will ask about it)"
    exit 0
fi

# Credentials are not enough on their own. Apple refuses anything that is not
# signed by a Developer ID with the hardened runtime, so submitting an ad-hoc
# build does not produce a warning — it produces a failed submission, and with
# it a red workflow and no release at all. A half-configured repository (Apple
# keys set, certificate not) should still ship, so this skips rather than dies.
# Written as a plain `if` rather than folded into the assignment. A command
# substitution that fails takes the whole script with it under `set -e`, and
# `[ -d ]` on a .dmg fails by design — so the one-liner version of this check
# killed the run before it printed anything, which is a worse failure than the
# one it was added to prevent.
SUBJECT=""
if [ -d "$TARGET" ]; then
    # --verbose=2, and the reason is the whole point of the line: at the
    # default verbosity `codesign -dv` does not print Authority at all. Asking
    # for it without asking loudly enough answers "unsigned" for every input,
    # so this guard skipped every build it was given — including correctly
    # signed ones — and nothing was ever notarised.
    SUBJECT="$(codesign -dv --verbose=2 "$TARGET" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
fi

if [ -d "$TARGET" ] && [ -z "$SUBJECT" ]; then
    echo "⚠ $TARGET is not signed with a Developer ID — skipping notarisation"
    echo "  Apple will not accept an ad-hoc signature. Set MACOS_CERTIFICATE_P12,"
    echo "  MACOS_CERTIFICATE_PASSWORD and MACOS_SIGNING_IDENTITY as well."
    exit 0
fi

CREDS=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")

# An .app cannot be uploaded as itself — the service takes an archive. A .dmg
# already is one.
case "$TARGET" in
    *.app)
        UPLOAD="${TARGET%.app}-notarize.zip"
        rm -f "$UPLOAD"
        # ditto, not zip: it preserves the extended attributes the signature
        # lives in. A zip(1) archive arrives looking unsigned.
        ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$UPLOAD"
        CLEANUP="$UPLOAD"
        ;;
    *)
        UPLOAD="$TARGET"
        CLEANUP=""
        ;;
esac

echo "Notarising $TARGET..."

# Submitted once, then polled here rather than by `notarytool --wait`.
#
# `--wait` couples two things that fail differently. Its timeout cannot tell a
# queue that is merely slow from a request that is never coming back, so when
# Apple took longer than half an hour — which it did, twice, with the service
# reporting itself healthy — the only recovery was to submit the same artefact
# again and start the wait over. Two attempts, an hour, no release, and Apple
# holding two copies of an identical upload.
#
# Polling separately means the upload happens exactly once. A slow queue costs
# patience instead of a resubmission, and a dropped connection — which is how
# the first real run died, on NSURLErrorDomain -1009 while waiting — is just a
# poll that returns nothing and is tried again.
SUBMISSION="$(xcrun notarytool submit "$UPLOAD" "${CREDS[@]}" --output-format json \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

if [ -z "$SUBMISSION" ]; then
    echo "✗ the submission was not accepted — nothing to wait for"
    [ -n "$CLEANUP" ] && rm -f "$CLEANUP"
    exit 1
fi
echo "  submission $SUBMISSION"

DEADLINE=$(( $(date +%s) + 3600 ))
STATUS="In Progress"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    # Every failure mode of this call — a dropped connection, a 500, a partial
    # body — lands on "Unknown", which simply means ask again in half a minute.
    STATUS="$(xcrun notarytool info "$SUBMISSION" "${CREDS[@]}" --output-format json 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","Unknown"))' 2>/dev/null || echo Unknown)"
    case "$STATUS" in
        Accepted) break ;;
        Invalid|Rejected) break ;;
        *) sleep 30 ;;
    esac
done

if [ "$STATUS" != "Accepted" ]; then
    echo "✗ notarisation ended as: $STATUS"
    # The log is the only place that says *why*, and it is the first thing
    # anyone will want. Fetching it costs one call and saves an hour.
    xcrun notarytool log "$SUBMISSION" "${CREDS[@]}" || true
    [ -n "$CLEANUP" ] && rm -f "$CLEANUP"
    exit 1
fi
[ -n "$CLEANUP" ] && rm -f "$CLEANUP"

# Staple the ticket into the artefact itself. Without this the check needs
# Apple reachable at first launch, so the one person who opens it on a plane
# gets the warning everybody else does not.
echo "Stapling..."
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# What the person downloading it will actually get. `spctl` is the same
# assessment Gatekeeper runs.
echo "Gatekeeper:"
if [ "${TARGET##*.}" = "app" ]; then
    spctl -a -vvv -t exec "$TARGET"
else
    spctl -a -vvv -t open --context context:primary-signature "$TARGET"
fi
echo "✓ notarised and stapled: $TARGET"
