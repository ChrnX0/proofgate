#!/usr/bin/env bash
# Guard: a `proofgate-allow` marker that suppresses nothing.
#
# The scar, and it is the gate's own: the marker is matched against the ADDED
# LINE ITSELF (`if (l !~ /proofgate-allow/)` in lib.sh). Written on the comment
# line above the code it means to excuse, it does nothing at all - while reading
# exactly like a handled finding. The author moves on, the warning keeps
# counting, and nobody looks because the summary only shows a number.
#
# That is worse than an unjustified warning: it is a "resolved" sign wired to
# nothing. Same family as a green test that exercises no rule.
#
# So: an added COMMENT-ONLY line carrying the marker is flagged. Put the marker
# on the offending line; keep the explanation in the comment where it belongs.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

BASE="${PROOFGATE_BASE:?PROOFGATE_BASE unset}"
# `\*` needs the JSDoc space after it, or markdown **bold** at line start matches.
COMMENT='^[[:space:]]*(//|#|--|\*[[:space:]]|/\*|<!--)'   # proofgate-allow

n=0
while IFS= read -r line; do
  content="${line:1}"
  printf '%s' "$content" | grep -Eq 'proofgate-allow' || continue
  printf '%s' "$content" | grep -Eq "$COMMENT"        || continue
  n=$((n + 1))
done < <(git diff "$BASE"..HEAD -- . ':(exclude)*.md' "${PG_SELF_EXCLUDE[@]}" 2>/dev/null |
           grep -E '^\+' | grep -v '^+++')

if [ "$n" -gt 0 ]; then
  echo "⚠️  dead-allow: $n added comment line(s) carry proofgate-allow, which only works on the offending line itself — those suppress nothing while reading as if they do. Move the marker onto the flagged line."
  exit 2
fi
echo "✅ dead-allow: every proofgate-allow sits on the line it excuses"
exit 0
