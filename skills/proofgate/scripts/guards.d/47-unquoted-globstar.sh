#!/usr/bin/env bash
# Guard: a `**` glob left unquoted inside an npm/yarn script.
#
# The scar: `"test": "tsx --test src/**/*.test.ts"`. The shell expands that
# before the runner ever sees it, and without `globstar` it reads `**` as a
# single directory level. A test file sitting one level shallower - or three
# levels deeper - is simply never executed, and the suite reports success for a
# file it never opened. A test that does not run is indistinguishable from a
# test that passes; this one hid for as long as nobody counted.
#
# Quoted, the pattern reaches the tool, which understands `**` at any depth.
# The fix is two characters, which is why the silence is the expensive part.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

# A JSON string value carrying `**`, with no shell quote anywhere inside it.
GLOB='"[a-zA-Z0-9:_-]+"[[:space:]]*:[[:space:]]*"[^"]*\*\*[^"]*"'   # proofgate-allow
QUOTED="['\\\\]"                                                     # proofgate-allow

tab="$(printf '\t')"; n=0
while IFS="$tab" read -r file content; do
  case "$file" in *package.json) ;; *) continue ;; esac
  printf '%s' "$content" | grep -Eq -- "$GLOB"   || continue
  printf '%s' "$content" | grep -Eq -- "$QUOTED" && continue   # already quoted for the shell
  pg_ignored "$(pg_fingerprint unquoted-globstar "$file" "$content")" && continue
  n=$((n + 1))
done < <(pg_added_with_file)

if [ "$n" -gt 0 ]; then
  echo "⚠️  unquoted-globstar: $n script(s) pass an unquoted ** glob to the shell, which flattens it to one directory level — files outside that level are skipped in silence. Quote the pattern so the tool expands it."
  exit 2
fi
echo "✅ unquoted-globstar: ** globs reach their tool intact"
exit 0
