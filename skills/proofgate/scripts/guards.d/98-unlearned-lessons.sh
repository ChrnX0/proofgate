#!/usr/bin/env bash
# Guard: a lesson is open — something broke, or a skeptic refused to drop a finding, and
# nothing at level 4 answers it yet.
#
# This is the SKILL's escalation ladder, enforced. The ladder says: in your head (1),
# prose in a doc (2), a line in the skill (3), a GUARD OR TEST that fails loud (4),
# impossible by construction (5) — and that only 4 and 5 stand on their own. Stopping at
# level 2 is named there as the anti-pattern, with a scar behind it: a rule written in
# plain words in a project's guidelines, and the mistake happened anyway.
#
# So a recorded incident opens a lesson, and the lesson stays open — the gate says so on
# every run — until something enforces it: a guard under guards.d/guardsDirs, a test, or
# an explicit `memory.sh add --resolves L-x`. That list of open lessons IS the tooling
# backlog the SKILL asks you to keep.
#
# ONE aggregated line, and `--snooze` exists, because a permanent nag is a nag people
# filter out. Exit: 0 = clean · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# This guard is diff-independent — an open lesson is open regardless of what changed —
# but the contract still requires PROOFGATE_BASE to be set, so assert it and move on.
# shellcheck disable=SC2034
BASE="${PROOFGATE_BASE:?}"

[ -f ".proofgate/lessons.jsonl" ] || { echo "✅ lessons: none recorded — guard skipped"; exit 0; }
command -v pg_lessons_open >/dev/null 2>&1 || { echo "✅ lessons: lib too old — guard skipped"; exit 0; }

OPEN="$(pg_lessons_open)"
[ -n "$OPEN" ] || { echo "✅ lessons: every recorded lesson has something enforcing it"; exit 0; }

# A lesson can also be answered by code: a guard or test that names its id. Only files
# that actually ENFORCE count — a `proofgate-lesson: L-3` comment dropped in a README
# would be level 2 wearing level 4's clothes, which is the exact confusion this guards.
ENFORCERS="$(git ls-files 2>/dev/null | grep -E '(guards\.d/|\.test\.|\.spec\.|_test\.|__tests__|(^|/)tests?/)' || true)"
STILL=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  id="$(printf '%s' "$l" | awk -F'\t' '{print $1}')"
  txt="$(printf '%s' "$l" | awk -F'\t' '{print $2}')"
  found=0
  if [ -n "$ENFORCERS" ]; then
    printf '%s\n' "$ENFORCERS" | while IFS= read -r f; do [ -f "$f" ] && grep -Fq "proofgate-lesson: $id" "$f" 2>/dev/null && echo hit; done | grep -q hit && found=1
  fi
  [ "$found" = 0 ] && STILL="$STILL
  $id  $txt"
done <<EOF
$OPEN
EOF

if [ -n "$(printf '%s' "$STILL" | grep -v '^$' || true)" ]; then
  n="$(printf '%s' "$STILL" | grep -c . || true)"
  echo "⚠️  lessons: $n scar(s) recorded with nothing enforcing them yet:$STILL"
  echo "    Writing a lesson down STORES it; only a guard or a test ENFORCES it — levels 1–3"
  echo "    of the ladder all depend on someone remembering at the right moment. Answer one"
  echo "    with a guard in guards.d (add \`proofgate-lesson: <id>\` to it), a regression test,"
  echo "    or \`memory.sh add --resolves <id> ...\` when the honest answer is 'documented only'."
  exit 2
fi
echo "✅ lessons: every open lesson has a guard or test behind it"
exit 0
