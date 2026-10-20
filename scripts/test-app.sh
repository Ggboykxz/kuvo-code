#!/bin/sh
# Runs the app's tests (KuvoCodeTests): scenarios run on the app's own code, hosted by a copy of
# the app that starts nothing (no window, engine or menu bar item) and keeps everything in the
# temporary folder.
#   ONLY   a suite or test to run alone, e.g. KuvoCodeTests/ChangesDiscardTests
#
# The test copy is built outside the checkout: a copy of the app loading its code from Desktop or
# Documents would wait on a privacy prompt nobody can answer while tests run. It has a bundle ID
# of its own, so it never shares the app's settings or keychain items.
set -eu
cd "$(dirname "$0")/.."

TEMP="${TMPDIR:-/tmp}"
BUILD="${TEMP%/}/KuvoCodeTests-build"
set -- -project KuvoCode.xcodeproj -scheme KuvoCode -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$BUILD" -clonedSourcePackagesDirPath build/SourcePackages \
    APP_BUNDLE_ID=run.kuvo.code.tests CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
if [ -n "${ONLY:-}" ]; then set -- "$@" -only-testing:"$ONLY"; fi

# The whole log in the build folder; here, each test's result, and what went wrong.
mkdir -p "$BUILD"
status=0
xcodebuild test "$@" > "$BUILD/test.log" 2>&1 || status=$?
grep -E '(✔|✘|􀢄|􁁛).*(Test|Suite)|issue|error:|\*\* TEST' "$BUILD/test.log" | grep -v 'warning:\|\[Connection\]' || true
if [ $status -ne 0 ]; then echo "The whole log: $BUILD/test.log" >&2; fi
# What the tests left: their data, Trash and repositories.
rm -rf "${TEMP%/}/KuvoCodeTests"
exit $status
