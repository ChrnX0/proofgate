#!/usr/bin/env bash
# Guard: env-var drift — code now reads a variable that .env.example doesn't declare.
# The classic "works on my machine, crashes on the first fresh deploy".
# Example file configurable: proofgate.json → "envExample" (default .env.example).
# Exit: 0 = clean/skipped · 2 = WARN.
set -uo pipefail
BASE="${PROOFGATE_BASE:?}"
CFG="${PROOFGATE_CFG:-proofgate.json}"

EXAMPLE=".env.example"
if [ -f "$CFG" ] && command -v jq >/dev/null 2>&1; then
  CUSTOM="$(jq -r '.envExample // empty' "$CFG" 2>/dev/null)"
  [ -n "$CUSTOM" ] && EXAMPLE="$CUSTOM"
fi
[ -f "$EXAMPLE" ] || { echo "✅ env-drift: no $EXAMPLE in repo — guard skipped"; exit 0; }

NEW_VARS=$(git diff "$BASE"..HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' \
  | grep -E '^\+' \
  | grep -oE 'process\.env\.[A-Z_][A-Z0-9_]*|os\.environ(\.get)?\(["'"'"'][A-Z_][A-Z0-9_]*|ENV\[["'"'"'][A-Z_][A-Z0-9_]*' \
  | grep -oE '[A-Z_][A-Z0-9_]{2,}$' | sort -u || true)

MISSING=""
for v in $NEW_VARS; do
  grep -q "^$v=" "$EXAMPLE" || grep -q "^# *$v=" "$EXAMPLE" || MISSING="$MISSING $v"
done

if [ -n "$MISSING" ]; then
  echo "⚠️  env-drift: code now reads$MISSING but $EXAMPLE doesn't declare it — first fresh deploy will crash"
  exit 2
fi
echo "✅ env-drift: every env var read in the diff is declared in $EXAMPLE"
exit 0
