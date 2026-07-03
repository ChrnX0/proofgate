#!/usr/bin/env bash
# Guard: secrets added in the diff (API keys, tokens, private keys).
# A leaked credential is the single most expensive line of code you can ship.
# Exit: 0 = clean · 1 = FAIL (secrets are never a warning).
set -uo pipefail
BASE="${PROOFGATE_BASE:?}"

# High-signal patterns only (low false-positive by design):
PATTERNS='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}|sk_live_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhbGciOi[A-Za-z0-9_-]{20,}\.'

HITS=$(git diff "$BASE"..HEAD -- . ':!*.lock' ':!*lock.yaml' ':!*lock.json' ':!*.env.example' ':!*.env.sample' \
  | grep -E '^\+' | grep -Ec "$PATTERNS" || true)

if [ "${HITS:-0}" -gt 0 ]; then
  echo "❌ secrets: $HITS added line(s) look like credentials (API key/token/private key). Remove and ROTATE them — a pushed secret is a burned secret."
  git diff "$BASE"..HEAD -- . ':!*.lock' ':!*lock.yaml' ':!*lock.json' ':!*.env.example' ':!*.env.sample' \
    | grep -En '^\+' | grep -E "$PATTERNS" | sed -E 's/^(.{60}).*/     \1…/' | head -5
  exit 1
fi
echo "✅ secrets: no credential-shaped lines added in the diff"
exit 0
