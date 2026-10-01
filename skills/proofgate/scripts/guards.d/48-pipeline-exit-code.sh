#!/usr/bin/env bash
# Guard: reading `$?` after a pipeline, in a script without `set -o pipefail`.
#
# The scar: `npm run e2e 2>&1 | tail -3` then `echo "exit: $?"`. That prints
# `tail`'s status, not the command whose success was being measured - and `tail`
# succeeds at printing three lines of a failure. The measurement read 0 while the
# thing under test read 1.
#
# What made it expensive: the run was checking whether a guard exits non-zero on
# an empty suite. "Prints the message but exits 0" was the exact defect being
# fixed, so the wrong reading looked like the bug reproducing. A measurement that
# can quietly answer about a different process is worse than no measurement.
#
# Only fires where `pipefail` is absent, because with it `$?` is the first
# failing stage and the reading is sound. Redirect to a file and check the
# command's own status, or turn on pipefail.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

BASE="${PROOFGATE_BASE:?PROOFGATE_BASE unset}"

# Pipelines whose last stage only formats: their exit status is never the answer.
FORMATTER='\|[[:space:]]*(tail|head|cut|tr|sort|uniq|column|fmt|jq|tee|less|cat)([[:space:]]|$)'  # proofgate-allow

n=0
while IFS= read -r file; do
  case "$file" in *.sh|*.bash|*.bats) ;; *) continue ;; esac
  [ -f "$file" ] || continue
  grep -Eq 'set[[:space:]]+-[a-z]*o[[:space:]]+pipefail|set[[:space:]]+-[a-z]*eo[[:space:]]+pipefail' "$file" && continue

  # A line with a formatter pipeline, immediately followed by one reading `$?`.
  prev=""
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -Eq '\$\?' && printf '%s' "$prev" | grep -Eq -- "$FORMATTER"; then
      pg_ignored "$(pg_fingerprint pipeline-exit-code "$file" "$line")" && { prev="$line"; continue; }
      n=$((n + 1))
    fi
    prev="$line"
  done < "$file"
done < <(git diff --name-only "$BASE"..HEAD -- . "${PG_SELF_EXCLUDE[@]}" 2>/dev/null)

if [ "$n" -gt 0 ]; then
  echo "⚠️  pipeline-exit-code: $n place(s) read \$? straight after a pipeline ending in a formatter, in a file without \`set -o pipefail\` — that reports the formatter's status, not the command being measured. Redirect to a file and check the command itself, or enable pipefail."
  exit 2
fi
echo "✅ pipeline-exit-code: exit codes are read from the command that produced them"
exit 0
