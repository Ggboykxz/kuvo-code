#!/bin/sh
# Writes Agents/test/groups-vectors.json: what the Mac's group chat rules say
# (KuvoCodeTests/GroupRulesVectorsTests), which a group chat that lives on a machine (the agents
# bridge's Agents/src/groups) must say too, and records the file's hash in that test. Run it after
# changing those rules, then the bridge's tests: `cd Agents && bun test`.
set -eu
cd "$(dirname "$0")/.."

TEMP="${TMPDIR:-/tmp}"
OUT="${TEMP%/}/kuvo-groups-vectors.json"
rm -f "$OUT"
# Passed to the test as KUVO_WRITE_GROUP_VECTORS (xcodebuild hands TEST_RUNNER_ variables on).
TEST_RUNNER_KUVO_WRITE_GROUP_VECTORS="$OUT" ONLY=KuvoCodeTests/GroupRulesVectorsTests ./scripts/test-app.sh >/dev/null
[ -s "$OUT" ] || { echo "The test didn't write the vectors." >&2; exit 1; }
mv -f "$OUT" Agents/test/groups-vectors.json
hash=$(shasum -a 256 Agents/test/groups-vectors.json | cut -d' ' -f1)
sed -i '' "s/static let recorded = \".*\"/static let recorded = \"$hash\"/" KuvoCodeTests/GroupRulesVectorsTests.swift
echo "Wrote Agents/test/groups-vectors.json ($hash)"
