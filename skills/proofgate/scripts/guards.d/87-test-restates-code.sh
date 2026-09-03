#!/usr/bin/env bash
# Guard: a test that recomputes the implementation's formula instead of stating
# the answer.
# The scar: a QR code's quiet zone is four modules by the standard, so the module
# exported `QUIET_ZONE = 4` and the test asserted
# `assert.equal(span, 21 + QUIET_ZONE * 2)` — importing the very constant it was
# checking. Both sides moved together: a mutant that zeroed the constant kept the
# test green, twice, and the margin the standard requires was protected by
# nothing. A test that restates the code proves the language's arithmetic works,
# not that the code is right.
# The fix is always the same and always cheap: write the literal. `assert.equal(span, 29)`
# fails the moment the constant changes, which is the entire point.
# WARN, never FAIL: comparing against an imported enum or a shared fixture is
# fine and common — what is flagged is arithmetic ON an imported symbol inside
# the expected value.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

ASSERT='assert\.(equal|strictEqual|deepEqual|deepStrictEqual)|expect\(|assertEquals|assert_eq!'
tab="$(printf '\t')"; n=0

while IFS="$tab" read -r file content; do
  case "$file" in
    *test*|*spec*|*Test.*) ;;
    *) continue ;;
  esac

  printf '%s' "$content" | grep -Eq "$ASSERT" || continue

  # An identifier with arithmetic next to it: `X * 2`, `21 + X`, `X - 1`.
  # Screaming-case first (constants are the common case), then any identifier
  # that the file imports from a RELATIVE module — the module under test.
  candidates="$(printf '%s' "$content" |
    grep -Eo '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[-+*/][[:space:]]*[0-9A-Za-z_]|[0-9A-Za-z_][[:space:]]*[-+*/][[:space:]]*[A-Za-z_][A-Za-z0-9_]*' |
    grep -Eo '[A-Za-z_][A-Za-z0-9_]{2,}' | sort -u)"
  [ -n "$candidates" ] || continue

  hit=''
  while read -r ident; do
    [ -n "$ident" ] || continue
    # Imported from a relative path in this same file? Then the test is doing the
    # implementation's arithmetic with the implementation's own number.
    if grep -Eq "^[[:space:]]*import[^;]*\b${ident}\b[^;]*from[[:space:]]*['\"]\.\.?/" "$file" 2>/dev/null; then
      hit="$ident"; break
    fi
  done <<EOF
$candidates
EOF
  [ -n "$hit" ] || continue

  pg_ignored "$(pg_fingerprint test-restates-code "$file" "$content")" && continue
  n=$((n + 1))
done < <(pg_added_with_file ':(exclude)*.md')

if [ "$n" -gt 0 ]; then
  echo "⚠️  test-restates-code: $n assertion(s) compute the expected value from a constant imported from the module under test. Both sides move together, so the test cannot fail — write the literal answer instead."
  exit 2
fi
echo "✅ test-restates-code: no assertion recomputes the code it checks"
exit 0
