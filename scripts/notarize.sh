#!/bin/bash
# Sends one artefact to Apple, waits for the verdict, and staples the ticket.
# A refusal stops the release. A queue that never answers does not: see the
# note above the verdict at the bottom of this file.
#
#   ./scripts/notarize.sh build/Corral.app
#   ./scripts/notarize.sh build/Corral-1.2.3.dmg
#
# Notarisation is not App Store review. Nobody looks at it: Apple scans the
# binary for malware and for the things a signature is supposed to guarantee,
# and usually answers in minutes — though not always; see the verdict below. What it buys is the difference between an app
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

# Polled here rather than by `notarytool --wait`, and submitted more than once
# if the first attempt goes quiet.
#
# `--wait` couples two things that fail differently: its timeout cannot tell a
# queue that is merely slow from a submission that is never coming back. Both
# happen. Asking Apple for its history of one day's uploads here returned nine
# submissions of the same small app — two Accepted, seven still "In Progress",
# the oldest of them twenty-two hours old — with the service reporting itself
# healthy throughout and not one refusal among them. A submission that sticks
# does not recover; the service will happily take another.
#
# So the budget is spent as several attempts rather than one long wait. It
# costs the same wall clock and the same runner, and the only thing it adds is
# a second upload of a two megabyte zip. Polling separately is what makes that
# possible, and it also means a dropped connection — which is how the first
# real run died, on NSURLErrorDomain -1009 — is just a poll that returns
# nothing and is tried again.
ATTEMPT_SECONDS="${NOTARY_ATTEMPT:-900}"
TOTAL_SECONDS="${NOTARY_TIMEOUT:-1800}"
OVERALL_DEADLINE=$(( $(date +%s) + TOTAL_SECONDS ))
STATUS="In Progress"
ATTEMPTS=""

while :; do
    SUBMISSION="$(xcrun notarytool submit "$UPLOAD" "${CREDS[@]}" --output-format json \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

    if [ -z "$SUBMISSION" ]; then
        echo "✗ the submission was not accepted — nothing to wait for"
        if [ -n "$CLEANUP" ]; then rm -f "$CLEANUP"; fi
        exit 1
    fi
    echo "  submission $SUBMISSION"
    ATTEMPTS="$ATTEMPTS $SUBMISSION"

    ATTEMPT_DEADLINE=$(( $(date +%s) + ATTEMPT_SECONDS ))
    if [ "$ATTEMPT_DEADLINE" -gt "$OVERALL_DEADLINE" ]; then
        ATTEMPT_DEADLINE="$OVERALL_DEADLINE"
    fi

    while [ "$(date +%s)" -lt "$ATTEMPT_DEADLINE" ]; do
        # Every failure mode of this call — a dropped connection, a 500, a
        # partial body — lands on "Unknown", which simply means ask again in
        # half a minute.
        STATUS="$(xcrun notarytool info "$SUBMISSION" "${CREDS[@]}" --output-format json 2>/dev/null \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","Unknown"))' 2>/dev/null || echo Unknown)"
        case "$STATUS" in
            Accepted|Invalid|Rejected) break ;;
            *) sleep 30 ;;
        esac
    done

    case "$STATUS" in
        Accepted|Invalid|Rejected) break ;;
    esac
    if [ "$(date +%s)" -ge "$OVERALL_DEADLINE" ]; then
        break
    fi
    echo "  no answer in $(( ATTEMPT_SECONDS / 60 )) minutes — submitting again"
done

# Spelt out rather than folded into an && chain. `set -e` tolerates a failing
# test on the left of an &&, but the reader has to know that to be sure, and
# the .dmg branch — the one where CLEANUP is empty — is the branch that has
# never actually run.
if [ -n "$CLEANUP" ]; then
    rm -f "$CLEANUP"
fi

# Three outcomes, and only two of them are ours.
#
# Apple saying no is a fault in what we sent: the wrong certificate, a missing
# hardened runtime, an unsigned nested binary. That has to stop the release,
# because shipping past it means shipping the thing Apple just objected to.
#
# Apple saying nothing is weather. The queue took over an hour for one small
# app on the day this was written, twice, with the service reporting itself
# healthy — and because a silence was treated the same as a refusal, four runs
# in a row published nothing at all while the newest download on the page
# stayed an ad-hoc build from before any of this existed. Waiting longer does
# not make Apple faster; it just spends a macOS runner to arrive at the same
# unanswered question.
#
# So a silence ships. The build is still Developer ID signed with the hardened
# runtime, which is most of the distance, and the release notes ask `stapler
# validate` rather than assuming — an unstapled build gets the right-click
# instructions, not a claim it cannot support. If Apple accepts the submission
# after we stop listening, the ticket exists on their side and Gatekeeper finds
# it online at first launch; stapling is what makes that work offline too, and
# `xcrun stapler staple` on a later build costs nothing to run.
case "$STATUS" in
    Accepted) ;;
    Invalid|Rejected)
        echo "✗ Apple rejected $TARGET — status: $STATUS"
        # The log is the only place that says *why*, and it is the first thing
        # anyone will want. Fetching it costs one call and saves an hour.
        xcrun notarytool log "$SUBMISSION" "${CREDS[@]}" || true
        exit 1
        ;;
    *)
        echo "⚠ Apple has not answered in $(( TOTAL_SECONDS / 60 )) minutes — last status: $STATUS"
        echo "  submissions:$ATTEMPTS"
        echo "  Shipping the signed build unstapled. The ticket can be added to"
        echo "  the published files later, without rebuilding, with the Staple"
        echo "  workflow — the same bytes are what Apple was asked about."
        exit 0
        ;;
esac

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
