#!/usr/bin/env bash
# Guard: coupled files — pairs that must change together (ORM schema ↔ SQL mirror,
# API contract ↔ client types, i18n keys ↔ translations). One side moving alone
# is silent drift you'll only meet in production.
# Configure: proofgate.json → "coupledFiles": [{ "a": "...", "b": "...", "reason": "..." }]
# Exit: 0 = clean/skipped · 2 = WARN.
set -uo pipefail
BASE="${PROOFGATE_BASE:?}"
CFG="${PROOFGATE_CFG:-proofgate.json}"

{ [ -f "$CFG" ] && command -v jq >/dev/null 2>&1; } || { echo "✅ coupled-files: no proofgate.json/jq — guard skipped"; exit 0; }
N=$(jq -r '.coupledFiles | length // 0' "$CFG" 2>/dev/null || echo 0)
[ "${N:-0}" -gt 0 ] || { echo "✅ coupled-files: no pairs configured — guard skipped"; exit 0; }

CHANGED="$(git diff --name-only "$BASE"..HEAD)"
DRIFT=0
for i in $(seq 0 $((N - 1))); do
  A=$(jq -r ".coupledFiles[$i].a" "$CFG"); B=$(jq -r ".coupledFiles[$i].b" "$CFG")
  R=$(jq -r ".coupledFiles[$i].reason // \"they must move together\"" "$CFG")
  A_CH=$(echo "$CHANGED" | grep -cx "$A" || true); B_CH=$(echo "$CHANGED" | grep -cx "$B" || true)
  if [ "$A_CH" != "$B_CH" ]; then
    echo "⚠️  coupled-files: $A and $B did NOT change together ($R)"
    DRIFT=$((DRIFT + 1))
  fi
done

[ "$DRIFT" -gt 0 ] && exit 2
echo "✅ coupled-files: all $N configured pair(s) moved together (or stayed still)"
exit 0
