#!/usr/bin/env bash
# Guard: a fix branch with no hypothesis on the record.
#
# The scar is the shape of every fix that fixed nothing: the work starts from a guess
# about the cause, the guess is never written down, and so it is never falsified — it
# just gets implemented. By the time the delivery is reported, the "root cause" section
# is written backwards from the change that was made, which is the one direction of
# reasoning that cannot be wrong and cannot be checked.
#
# WARN, never FAIL, and only on a branch or commit that announces itself as a fix.
# Branch naming is not universal (configurable via hypothesis.branchPattern), plenty of
# fixes are one-liners whose cause is self-evident from the diff, and a gate that
# demands ceremony for a typo is a gate people route around.
#
# Exit: 0 = clean/not applicable · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
BASE="${PROOFGATE_BASE:?}"

PAT="$(cfg '.hypothesis.branchPattern' 2>/dev/null)"; PAT="${PAT:-(^|/)(fix|bugfix|hotfix|patch)}"

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
SUBJECTS="$(git log --format=%s "$BASE"..HEAD 2>/dev/null || true)"

is_fix=0
printf '%s' "$BRANCH" | grep -Eqi "$PAT" && is_fix=1
printf '%s\n' "$SUBJECTS" | grep -Eqi "^(fix|bugfix|hotfix)(\(|:|[[:space:]])" && is_fix=1
[ "$is_fix" = 1 ] || { echo "✅ hypothesis: not a fix delivery — guard not applicable"; exit 0; }

GD="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
LEDGER="$GD/proofgate-hypotheses.jsonl"
if [ -f "$LEDGER" ] && grep -q '"event":"' "$LEDGER" 2>/dev/null; then
  echo "✅ hypothesis: this fix has a hypothesis on the record"
  exit 0
fi

echo "⚠️  hypothesis: this looks like a fix, and no hypothesis was ever recorded."
echo "    A cause that is never written down is never falsified — it just gets implemented,"
echo "    and the root-cause section ends up written backwards from the change. State the"
echo "    mechanism and what MUST be true if it holds:"
echo "      hypothesis.sh open --kind bugfix --hypothesis \"<the mechanism>\" \\"
echo "        --prediction \"<the mark that must exist>\" --cmd \"<the command that reveals it>\""
exit 2
