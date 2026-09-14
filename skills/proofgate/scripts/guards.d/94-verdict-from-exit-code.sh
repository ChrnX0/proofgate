#!/usr/bin/env bash
# Guard: a pass/fail verdict decided by grepping output instead of the exit code.
#
# The scar: a mutation-testing run reported SURVIVED for five mutations in a row —
# including one that re-introduced the exact regression the tests had just been
# written to catch. The tests were fine. The judge was broken:
#
#     out=$(vitest run target | tail -3)
#     if echo "$out" | grep -q "failed"; then KILLED; else SURVIVED; fi
#
# `tail -3` of that runner returns "Start at" and "Duration"; the `Tests N failed`
# line sits above the cut. The grep could never match, and "I did not find a
# failure" silently became "it passed". A judge that can only say one thing.
#
# The general rule this guards: a command's verdict is its EXIT CODE, never a
# pattern match on its formatted output. Output filters are for COUNTING after you
# already know it failed ("how many type errors?"), not for deciding whether it
# failed. Runners change their summary wording between versions, localize it, hide
# it behind a progress bar, or push it past whatever `tail`/`head` kept — and every
# one of those turns a red run green.
#
# The discriminator is capture-or-condition: piping output to `tail` just to READ
# it is fine; using that text as the verdict — inside an `if`, behind `&&`/`||`,
# or captured into `$( )` — is the sin. Comment lines are excluded: they decide
# nothing, and without that filter this guard flags its own example above.
#
# Sibling of the 3.0.1 excuse-breaker (a PIPELINE's `$?` is the last command's):
# there the exit code was read from the wrong process; here it is not read at all.
# Exit: 0 = clean · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

# Test/build runners whose result someone might be tempted to read from the text.
RUNNERS='vitest|jest|mocha|pytest|nose2|rspec|phpunit|go test|cargo test|dotnet test|gradle test|mvn test|(npm|pnpm|yarn|bun)([[:space:]]+run)?[[:space:]]+(test|build|lint|typecheck)|tsc|next build|make test'  # proofgate-allow
# The output filter the verdict is (wrongly) being read through.
FILTERS='\|[[:space:]]*(grep|tail|head|awk|sed)'                                                                                                                                                              # proofgate-allow
# Capture or condition — what turns "reading" into "judging".
JUDGES='(^|[[:space:]])if[[:space:]]|&&|\|\||\$\('                                                                                                                                                            # proofgate-allow

tab="$(printf '\t')"
sujo=""
while IFS="$tab" read -r file line; do
  case "$file" in *.sh|*.bash|*.zsh|*.yml|*.yaml|Makefile|*/Makefile) ;; *) continue ;; esac
  # A comment decides nothing — and a guard that documents the sin must not trip
  # on its own documentation.
  case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in \#*) continue ;; esac
  printf '%s' "$line" | grep -Eq -- "$RUNNERS" || continue
  printf '%s' "$line" | grep -Eq -- "$FILTERS"  || continue
  printf '%s' "$line" | grep -Eq -- "$JUDGES"   || continue
  pg_ignored "$(pg_fingerprint verdict-from-exit-code "$file" "$line")" \
    && pg_calib verdict-from-exit-code allowed "$file (.proofgateignore)" \
    && continue
  sujo="$sujo
    $file: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-110)"
done < <(pg_added_with_file ':(exclude)*.md')

if [ -n "$sujo" ]; then
  echo "⚠️  verdict-from-exit-code: a test/build result is being judged by matching its OUTPUT:$sujo"
  echo "    The filter can cut the very line that reports the failure — that is how five mutations"
  echo "    once 'survived' against tests that did catch them. Let the exit code decide:"
  echo "        if cmd > out.log 2>&1; then PASSED; else FAILED; fi"
  echo "    and only then COUNT in the file (grep -c 'error') what you want to report."
  exit 2
fi

echo "✅ verdict-from-exit-code: no test/build verdict read from matched output"
exit 0
