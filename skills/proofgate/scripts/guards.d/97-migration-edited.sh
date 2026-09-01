#!/usr/bin/env bash
# Guard: a migration step that already exists being edited instead of appended.
#
# The scar: migrations are append-only for a reason that has no workaround. A
# step that has already run somewhere leaves that database in the shape the OLD
# text produced. Editing the file changes what a FRESH database gets and nothing
# else - so the two diverge, in silence, and every checkout is fine. It surfaces
# months later as a column that exists on one machine and not another.
#
# Adding files here is normal and is not flagged. Only modification of a file
# that already existed in the base is, and deletion of one.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

BASE="${PROOFGATE_BASE:?PROOFGATE_BASE unset}"
touched=""; n=0
while IFS=$'\t' read -r status file; do
  case "$status" in M*|D*|R*) ;; *) continue ;; esac
  # The DIRECTORY, not the word: `scripts/verify-migrations.sh` verifies
  # migrations, it is not one, and a guard that cannot tell the two apart gets
  # switched off by the first person it annoys.
  case "$file" in
    migrations/*|*/migrations/*|db/migrate/*|*/db/migrate/*|*/alembic/versions/*|db/schema.rb|*/db/schema.rb) ;;
    *) continue ;;
  esac
  case "$file" in *.md|*.txt|*README*) continue ;; esac
  pg_ignored "$(pg_fingerprint migration-edited "$file" "$status")" && continue
  n=$((n + 1)); touched="$touched $file"
done < <(git diff --name-status "$BASE"..HEAD -- . "${PG_SELF_EXCLUDE[@]}" 2>/dev/null)

if [ "$n" -gt 0 ]; then
  echo "⚠️  migration-edited: $n existing migration file(s) modified or removed —$touched. A step that already ran leaves that database in the OLD shape while a fresh one gets the new: they diverge silently. Append a new step instead."
  exit 2
fi
echo "✅ migration-edited: migrations only grew"
exit 0
