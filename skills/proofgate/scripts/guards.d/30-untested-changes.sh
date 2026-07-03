#!/usr/bin/env bash
# Guard: source changed, zero test files changed.
# Not every diff needs new tests — but "none of them do" is how regressions ship.
# Source dirs configurable: proofgate.json → "sourceGlobs" (default "src/|lib/|app/").
# Exit: 0 = clean · 2 = WARN.
set -uo pipefail
BASE="${PROOFGATE_BASE:?}"
CFG="${PROOFGATE_CFG:-proofgate.json}"

SRC="src/|lib/|app/"
if [ -f "$CFG" ] && command -v jq >/dev/null 2>&1; then
  CUSTOM="$(jq -r '.sourceGlobs // empty' "$CFG" 2>/dev/null)"
  [ -n "$CUSTOM" ] && SRC="$CUSTOM"
fi

CHANGED="$(git diff --name-only "$BASE"..HEAD)"
SRC_N=$(echo "$CHANGED" | grep -E "($SRC)" | grep -Ev '(\.test\.|\.spec\.|__tests__|_test\.|/tests?/)' | grep -Ec '\.(ts|tsx|js|jsx|py|rb|go|rs|java|kt)$' || true)
TEST_N=$(echo "$CHANGED" | grep -Ec '(\.test\.|\.spec\.|__tests__|_test\.|/tests?/)' || true)

if [ "${SRC_N:-0}" -gt 0 ] && [ "${TEST_N:-0}" -eq 0 ]; then
  echo "⚠️  untested changes: $SRC_N source file(s) changed, 0 test files touched — is the new behavior pinned by any test?"
  exit 2
fi
echo "✅ tests-changed: $SRC_N source / $TEST_N test file(s) in the diff"
exit 0
