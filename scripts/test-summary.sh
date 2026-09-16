#!/usr/bin/env bash
#
# Report the outcome of an `xcodebuild test` run from its .xcresult bundle.
#
# The xcodebuild console stream is not a reliable report: swift-testing cases are
# printed inconsistently, so grepping it showed roughly 30 of the suite's 72 tests
# and no totals. The result bundle is authoritative, so read that and exit non-zero
# when anything failed.
#
# Usage: scripts/test-summary.sh <path/to/result.xcresult>

set -euo pipefail

BUNDLE="${1:?usage: test-summary.sh <path/to/result.xcresult>}"

if [ ! -d "$BUNDLE" ]; then
    echo "No result bundle at $BUNDLE — the test run did not produce one." >&2
    exit 1
fi

xcrun xcresulttool get test-results summary --path "$BUNDLE" | python3 -c '
import json, sys

d = json.load(sys.stdin)
result = d.get("result", "Unknown")
passed = d.get("passedTests", 0)
failed = d.get("failedTests", 0)
skipped = d.get("skippedTests", 0)
total = d.get("totalTestCount", passed + failed + skipped)

for f in d.get("testFailures") or []:
    name = f.get("testName") or f.get("testIdentifier") or "<unknown test>"
    target = f.get("targetName", "")
    print(f"FAIL {name}" + (f" [{target}]" if target else ""))
    for line in (f.get("failureText") or "").strip().splitlines():
        print(f"     {line}")

print(f"{result}: {passed} passed, {failed} failed, {skipped} skipped ({total} total)")
sys.exit(1 if failed or result not in ("Passed", "Expected Failure") else 0)
'
