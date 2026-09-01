#!/usr/bin/env bash
# Guard: a verification script that reaches Postgres as a superuser, in a repo
# that defends itself with row level security.
#
# The scar: a schema harness replayed the client's whole write queue against a
# real Postgres and passed - forty-five writes, not one refusal. It connected as
# `postgres`. A superuser BYPASSES RLS entirely, so every policy was off. The
# run proved the columns agreed and nothing whatsoever about whether the server
# would accept the writes; the one rule that decided the feature was never
# executed. A wrong premise then survived a full green bar and got built upon.
#
# Only fires where policies exist - a repo without RLS has nothing to bypass.
# Warn, never fail: setup and migration steps legitimately need the superuser.
# What it asks is that the part imitating the client run as the client does.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

git grep -qiE 'create policy|enable row level security' -- . ':(exclude)*/.proofgate/*' 2>/dev/null || {
  echo "✅ superuser-verification: no row level security in repo — guard skipped"; exit 0; }

SUPER='-U[[:space:]]*postgres|PGUSER=postgres|psql[[:space:]]+(-[^[:space:]]+[[:space:]]+)*postgres[[:space:]]|user:[[:space:]]*.postgres.|set[[:space:]]+role[[:space:]]+postgres'  # proofgate-allow

# Prose describing the sin is not the sin. This guard's own explanation of why
# `-U postgres` is wrong fired it on the first run - and a guard that flags the
# comment warning against it teaches people to stop writing the comment.
COMMENT='^[[:space:]]*(#|//|--|\*[[:space:]])'   # proofgate-allow

# `--` is not decoration: $SUPER starts with `-U`, and without it grep reads the
# pattern as an option and silently matches nothing. The guard passed everything.
n=0
tab="$(printf '\t')"
while IFS="$tab" read -r file content; do
  printf '%s' "$content" | grep -Eq -- "$SUPER"   || continue
  printf '%s' "$content" | grep -Eq -- "$COMMENT" && continue
  pg_ignored "$(pg_fingerprint superuser-verification "$file" "$content")" && continue
  n=$((n + 1))
done < <(pg_added_with_file '*test*' '*spec*' '*verify*' '*e2e*' '*fixture*' '*harness*')

if [ "$n" -gt 0 ]; then
  echo "⚠️  superuser-verification: $n added line(s) let a test/verification path connect to Postgres as a superuser. Superusers bypass RLS, so policies are NOT exercised — the run proves shape, not acceptance. Have the part that imitates the client connect as the client's role."
  exit 2
fi
echo "✅ superuser-verification: verification paths don't bypass row level security"
exit 0
