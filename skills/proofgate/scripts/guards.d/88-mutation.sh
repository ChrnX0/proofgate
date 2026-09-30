#!/usr/bin/env bash
# Guard: the project's curated mutation list — does it exist, does every entry still match the
# code, is the last verdict recent and about THIS code, and did a rule-bearing file move
# without a new mutation?
#
# The scar: a green suite is evidence about the suite, not about the code (2.4.0). The proof
# that a test can see is to break the code on purpose — and that proof goes stale silently.
# The project that ran it the longest found three ways it lies: an anchor stopped matching
# after a refactor and only the 14-minute full run noticed; a workshop that could not run the
# suite reported "all 90 defects caught"; and the verdict everyone quoted described code that
# had since changed. The full run takes minutes to hours, so THIS guard never runs it — it reads
# the list and the last verdict, in milliseconds, and says when they no longer describe the code.
#
# OPT-IN by configuration. Without `mutation.list` in proofgate.json it prints one line saying
# so and exits 0 — a project that has not adopted mutation testing is not failed for it.
#
#   "mutation": {
#     "list": "mutations.jsonl",      // one JSON object per line — see mutate-list.mjs
#     "command": "npm test",          // the suite; printed in the hint, run by you or by CI
#     "maxAgeDays": 14,               // a verdict older than this is stale
#     "riskyGlobs": "(^|/)(price|ledger)"   // paths whose change wants a NEW mutation (default: money/permission words)
#   }
#
# Exit: 0 = pass · 1 = FAIL (list missing, or an anchor cannot be planted) · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
BASE="${PROOFGATE_BASE:?}"

LIST="$(cfg '.mutation.list')"
[ -n "$LIST" ] || { echo "✅ mutation: not configured (set mutation.list in proofgate.json to adopt mutation testing) — guard skipped"; exit 0; }
[ -f "$LIST" ] || { echo "❌ mutation: mutation.list points at '$LIST', which does not exist — the rules it was meant to guard have nothing"; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$HERE/mutate.mjs"
CMD="$(cfg '.mutation.command')"; CMD="${CMD:-<your suite>}"
MAXAGE="$(cfg '.mutation.maxAgeDays')"; MAXAGE="${MAXAGE:-14}"
command -v node >/dev/null 2>&1 || { echo "⚠️  mutation: node not found — cannot check the anchors of $LIST"; exit 2; }
[ -f "$RUNNER" ] || { echo "⚠️  mutation: mutate.mjs missing next to the guards — reinstall (install.sh copies every script)"; exit 2; }

# FAIL (1) must beat WARN (2) — the codes are not ordered by severity, so keep them apart.
FAILED=0 WARNED=0
note() { echo "$1"; if [ "$2" = 1 ]; then FAILED=1; else WARNED=1; fi; }

# 1. every mutation still matches the code, exactly once. Stale or ambiguous = cannot be planted = FAIL.
if ! OUT="$(node "$RUNNER" --list "$LIST" --check 2>&1)"; then
  note "❌ mutation: anchors that cannot be planted in $LIST:" 1
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# 2. the last verdict is recent and covers the files as they are now.
ST="$(node "$RUNNER" --list "$LIST" --status --max-age-days "$MAXAGE" 2>&1)"; SC=$?
if [ "$SC" -ne 0 ]; then
  note "$ST" 2
  echo "    full run:  node $(basename "$RUNNER") --list $LIST -- $CMD   (slice it with --slice i/n when the suite is slow)"
fi

# 3. a file that carries a rule changed, and no mutation was added with it → a warning, not a verdict:
#    the cheap proxy for "new behaviour with no proof a test can see it".
RISKY="$(cfg '.mutation.riskyGlobs')"
RISKY="${RISKY:-$(cfg '.sensitiveGlobs')}"
RISKY="${RISKY:-(^|/)(auth|oauth|session|permission|acl|rbac|billing|payment|checkout|crypto|price|pricing|money|ledger|invoice|tax|rate.?limit)s?(/|[._-])}"
TEST_RE='(\.test\.|\.spec\.|__tests__|_test\.|(^|/)tests?/)'
CHANGED="$(git diff --name-only "$BASE"..HEAD 2>/dev/null | grep -Ev "$TEST_RE|\.(md|mdx|txt|rst)$|^\.proofgate/" | grep -E "$RISKY" | grep -vxF "$LIST" || true)"
if [ -n "$CHANGED" ]; then
  ADDED="$(git diff "$BASE"..HEAD -- "$LIST" 2>/dev/null | grep -c '^+[^+]' || true)"
  if [ "${ADDED:-0}" -eq 0 ]; then
    NAMES="$(printf '%s\n' "$CHANGED" | head -4 | paste -sd, - | sed 's/,/, /g')"
    note "⚠️  mutation: rule-bearing file(s) changed with no new mutation in $LIST: $NAMES" 2
    echo "    Every defect fixed gains a mutation — the cheapest proof the test written beside the fix bites."
  fi
fi

[ "$FAILED" = 1 ] && exit 1
[ "$WARNED" = 1 ] && exit 2
echo "✅ mutation: list present, every anchor matches once, verdict recent and about this code${CHANGED:+, new mutation accompanies the rule change}"
exit 0
