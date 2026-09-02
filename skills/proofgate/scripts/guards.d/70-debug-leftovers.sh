#!/usr/bin/env bash
# Guard: debug leftovers in the diff.
# `.only` on a test is the sneakiest one: it silently disables the REST of the
# suite — CI goes green because almost nothing ran. That one is a hard FAIL.
# `debugger` / stray `console.log` / fresh TODOs are warnings to justify.
# Exit: 0 = clean · 1 = FAIL (.only/focused tests) · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# The range now comes from pg_added_lines (which reads PROOFGATE_BASE itself); this
# assertion stays because the contract still requires the variable to be set.
# shellcheck disable=SC2034
BASE="${PROOFGATE_BASE:?}"

# Via the shared helper, so this guard also works in LIVE mode (the edit-notice hook
# runs it against the working tree the moment a file is written). A `.only` is cheapest
# to catch in the ten seconds after typing it, not at the gate.
ADDED="$(pg_added_lines '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs')"

FOCUS=$(echo "$ADDED" | grep -Ec '\b(it|test|describe)\.only\(|\bf(describe|it)\(' || true)
if [ "${FOCUS:-0}" -gt 0 ]; then
  echo "❌ debug-leftovers: $FOCUS focused test(s) added (.only/fdescribe/fit) — the rest of the suite is silently OFF. Green CI would be a lie."
  exit 1
fi

DEBUGS=$(echo "$ADDED" | grep -Ec '\bdebugger\b|console\.log\(|binding\.pry|breakpoint\(\)' || true)
TODOS=$(echo "$ADDED" | grep -Ec '\b(TODO|FIXME|HACK)\b' || true)
if [ "$((${DEBUGS:-0} + ${TODOS:-0}))" -gt 0 ]; then
  echo "⚠️  debug-leftovers: ${DEBUGS:-0} debug statement(s) + ${TODOS:-0} fresh TODO/FIXME in the diff — shipping them? justify in your status"
  exit 2
fi
echo "✅ debug-leftovers: no focused tests, debug statements or fresh TODOs added"
exit 0
