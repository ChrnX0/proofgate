#!/usr/bin/env bash
# Guard: an L3 change with no adversarial pass on the record.
#
# The blast radius already decided this one — L3 means auth, money, migrations, crypto,
# permissions, or a symptom that has survived two refuted explanations. In those areas the
# cost of a defect is not proportional to the size of the diff, which is exactly why the
# usual heuristic (small change, small review) fails there.
#
# WARN by default rather than FAIL: teams adopt the panel gradually, and a hard block on
# a step nobody has wired up yet is how a gate gets bypassed wholesale. `requireSkeptic`
# makes it a FAIL for teams that have.
#
# Exit: 0 = not applicable / satisfied · 1 = FAIL (requireSkeptic) · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# shellcheck disable=SC2034
BASE="${PROOFGATE_BASE:?}"

GD="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
IMPACT="$GD/proofgate-impact.json"
[ -f "$IMPACT" ] || { echo "✅ skeptic-required: no blast radius computed — guard skipped"; exit 0; }
grep -q '"skeptic_required":true' "$IMPACT" 2>/dev/null || { echo "✅ skeptic-required: this change does not demand an adversarial pass"; exit 0; }

WHY="$(grep -o '"risk_reasons":\[[^]]*\]' "$IMPACT" 2>/dev/null | head -c 160)"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SK="$GD/proofgate-skeptic.json"

msg() {
  echo "$1 skeptic-required: this change is L3 and $2"
  echo "    L3 means the cost of a defect here is not proportional to the size of the diff —"
  echo "    auth, money, migrations, crypto, permissions, or a symptom that already survived"
  echo "    two explanations. $WHY"
  echo "    Run the panel: /proofgate:gate (it launches gate-skeptic + security-skeptic and"
  echo "    records the findings, re-running every claimed repro)."
}

if [ ! -f "$SK" ]; then
  if [ "$(cfg '.requireSkeptic')" = "true" ]; then msg "❌" "no adversarial pass was recorded."; exit 1; fi
  msg "⚠️ " "no adversarial pass was recorded."; exit 2
fi
if ! grep -q "\"head_sha\":\"$HEAD_SHA\"" "$SK" 2>/dev/null; then
  if [ "$(cfg '.requireSkeptic')" = "true" ]; then msg "❌" "the recorded pass is for a DIFFERENT commit — the code moved after it ran."; exit 1; fi
  msg "⚠️ " "the recorded pass is for a DIFFERENT commit — the code moved after it ran."; exit 2
fi
if ! grep -q '"agent":"security-skeptic"' "$SK" 2>/dev/null; then
  if [ "$(cfg '.requireSkeptic')" = "true" ]; then msg "❌" "the security-skeptic did not run (only the general pass did)."; exit 1; fi
  msg "⚠️ " "the security-skeptic did not run (only the general pass did)."; exit 2
fi

OPEN="$(grep -o '"verdict":"REFUTED"' "$SK" 2>/dev/null | pg_count)"
if [ "${OPEN:-0}" -gt 0 ]; then
  echo "❌ skeptic-required: $OPEN refutation(s) REPRODUCED and are still open. Each one is a"
  echo "    command that fails today on this diff — not an opinion. Fix them, or record why"
  echo "    the failure is acceptable, before this can be called done."
  exit 1
fi
echo "✅ skeptic-required: adversarial pass recorded for ${HEAD_SHA:0:7}, no reproducing refutations"
exit 0
