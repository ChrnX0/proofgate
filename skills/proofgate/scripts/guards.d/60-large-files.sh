#!/usr/bin/env bash
# Guard: large files entering the repo. A 40MB "quick test video" committed by
# accident lives in your git history FOREVER — every clone pays for it.
# Threshold: 2MB (override with PROOFGATE_MAX_FILE_KB).
# Exit: 0 = clean · 2 = WARN.
set -uo pipefail
BASE="${PROOFGATE_BASE:?}"
MAX_KB="${PROOFGATE_MAX_FILE_KB:-2048}"

BIG=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  KB=$(( $(wc -c < "$f") / 1024 ))
  [ "$KB" -gt "$MAX_KB" ] && BIG="$BIG
     $f (${KB}KB)"
done < <(git diff --name-only --diff-filter=AM "$BASE"..HEAD)

if [ -n "$BIG" ]; then
  echo "⚠️  large-files: file(s) over ${MAX_KB}KB entering history:$BIG"
  echo "     (binary assets belong in object storage/LFS, not git)"
  exit 2
fi
echo "✅ large-files: nothing over ${MAX_KB}KB added"
exit 0
