#!/usr/bin/env bash
# Guard: a SQL statement built by string concatenation / interpolation.
# The scar: `"SELECT ... WHERE id = " + userInput` (or an f-string / template
# literal doing the same) is the textbook SQL-injection hole — one `'; DROP TABLE`
# away from disaster. Use parameterized queries / bound params. Medium false-
# positive rate (ORMs, query builders, tagged `sql`` templates), so this is always
# WARN, never FAIL, and tagged-template `sql`...`` is excluded.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
SQL='SELECT[[:space:]].*[[:space:]]FROM[[:space:]]|INSERT[[:space:]]+INTO[[:space:]]|UPDATE[[:space:]].*[[:space:]]SET[[:space:]]|DELETE[[:space:]]+FROM[[:space:]]'  # proofgate-allow
CONCAT='["'"'"'`][[:space:]]*\+|\+[[:space:]]*["'"'"'`]|\$\{|%s|%d|f["'"'"']|\.format[[:space:]]*\('  # proofgate-allow
# SQL's concatenation operator, kept apart from the rest for one reason: in a
# shell script `||` is or, and `psql -c "insert into t ...;" || fail` has exactly
# the shape of `'abc' || col` - a quote, then the bars. Nothing on the line tells
# them apart, so the file type does: shell scripts are excluded from this branch
# alone, and keep every other pattern above.
PIPE='["'"'"'][[:space:]]*\|\||\|\|[[:space:]]*["'"'"']'   # proofgate-allow
tab="$(printf '\t')"; n=0
while IFS="$tab" read -r file content; do
  printf '%s' "$content" | grep -Eiq "$SQL"    || continue       # a SQL verb AND
  if ! printf '%s' "$content" | grep -Eq "$CONCAT"; then           # a concat/interp on the same line
    case "$file" in *.sh|*.bash|*.zsh|*.bats) continue ;; esac      # ...or SQL's `||`, but not the shell's
    printf '%s' "$content" | grep -Eq "$PIPE" || continue
  fi
  printf '%s' "$content" | grep -Eq  'sql`'     && continue       # tagged template `sql`...`` is safe
  pg_ignored "$(pg_fingerprint sql-concat "$file" "$content")" && continue
  n=$((n + 1))
done < <(pg_added_with_file ':(exclude)*.md' ':(exclude)*test*' ':(exclude)*spec*')
if [ "$n" -gt 0 ]; then
  echo "⚠️  sql-concat: $n added line(s) build SQL by string concat/interpolation — an injection risk. Use parameterized/bound queries. (Query-builder false positive? suppress with proofgate-allow.)"
  exit 2
fi
echo "✅ sql-concat: no hand-concatenated SQL in the diff"
exit 0
