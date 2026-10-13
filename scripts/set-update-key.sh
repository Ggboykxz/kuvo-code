#!/bin/sh
# Uploads the update signing key for the release workflow.
#   scripts/set-update-key.sh
# Sets SPARKLE_PRIVATE_KEY from the key in your login keychain, the one every
# Kuvo app signs its updates with, after checking that it matches the public key
# in scripts/build-app.sh. macOS asks you to allow access to the key.
set -eu
cd "$(dirname "$0")/.."

REPO=${REPO:-serhatandic/kuvo-code}

TOOL=$(find build/SourcePackages/artifacts -path '*/Sparkle/bin/generate_keys' -type f | head -n 1)
if [ -z "$TOOL" ]; then
    echo "generate_keys not found; build the app first (scripts/build-app.sh)." >&2
    exit 1
fi

EXPECTED=$(sed -n 's/^UPDATE_PUBLIC_KEY="\(.*\)"/\1/p' scripts/build-app.sh)
ACTUAL=$("$TOOL" -p 2>/dev/null || true)
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "The update key in your keychain doesn't match scripts/build-app.sh. Nothing was uploaded." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$TOOL" -x "$TMP/key"
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$TMP/key"
echo "Updated SPARKLE_PRIVATE_KEY on $REPO."
