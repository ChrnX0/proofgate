#!/usr/bin/env bash
# Guard: a project-memory fact is anchored to a file this diff touches, and the anchor
# has drifted — the code it described is not the code that is there now.
#
# The scar this prevents is subtle and expensive: memory that is WRONG is worse than no
# memory. A note that was true in March reads exactly like one that is true today, and
# the reader — often a model with no way to check — builds on it. So the anchor is the
# whole feature, and this guard is the moment it pays off: you are editing the very file
# a recorded fact was about, which is precisely when believing the stale version does
# damage.
#
# WARN, one aggregated line, and ONLY when the stale fact's anchor is in the diff.
# Warning about every stale fact in the repository on every run would be wallpaper
# within a week, and wallpaper is how a gate stops being read.
#
# Exit: 0 = clean/not applicable · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
BASE="${PROOFGATE_BASE:?}"

LEDGER=".proofgate/memory.jsonl"
[ -f "$LEDGER" ] || { echo "✅ memory-stale: no project memory recorded — guard skipped"; exit 0; }

MEM_SH="$(dirname "$0")/../memory.sh"
[ -f "$MEM_SH" ] || { echo "✅ memory-stale: memory.sh not available — guard skipped"; exit 0; }

CHANGED="$(git diff --name-only "$BASE"..HEAD 2>/dev/null; git diff --name-only 2>/dev/null)"
[ -n "$CHANGED" ] || { echo "✅ memory-stale: nothing in the diff"; exit 0; }

STALE="$(bash "$MEM_SH" list --stale 2>/dev/null || true)"
[ -n "$STALE" ] || { echo "✅ memory-stale: every anchored fact still matches its code"; exit 0; }

HITS=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id="$(printf '%s' "$line" | awk '{print $1}')"
  row="$(grep "\"id\":\"$id\"" "$LEDGER" 2>/dev/null | head -1)"
  paths="$(printf '%s' "$row" | grep -o '"path":"[^"]*"' | sed -e 's/^"path":"//' -e 's/"$//')"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$CHANGED" | grep -Fxq "$p" && HITS="$HITS $id"
  done <<EOF
$paths
EOF
done <<EOF
$STALE
EOF

HITS="$(printf '%s' "$HITS" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ')"
if [ -n "$HITS" ]; then
  echo "⚠️  memory-stale: this diff touches files that recorded facts are anchored to, and those anchors no longer match:$HITS"
  echo "    Memory that is WRONG is worse than none — it reads exactly like memory that is right."
  echo "    Re-verify against the code as it is now, then \`memory.sh revoke <id> --reason ...\`"
  echo "    or record the corrected fact. (\`memory.sh show <id>\` for the original.)"
  exit 2
fi
echo "✅ memory-stale: no stale fact is anchored to a file in this diff"
exit 0
