#!/usr/bin/env bash
# Guard: PII flowing into logs/telemetry in ADDED lines.
# Personal data in a log file outlives every retention policy you think you have.
# Term list is configurable: proofgate.json → "piiTerms" (regex alternation).
# Exit: 0 = clean · 2 = WARN (1 under --strict via the runner).
set -uo pipefail
BASE="${PROOFGATE_BASE:?}"
CFG="${PROOFGATE_CFG:-proofgate.json}"

TERMS="password|passwd|ssn|social.?security|cpf|credit.?card|card.?number|cvv|phone|e-?mail|date.?of.?birth|birth.?date|medical|diagnosis|health|address|passport"
if [ -f "$CFG" ] && command -v jq >/dev/null 2>&1; then
  CUSTOM="$(jq -r '.piiTerms // empty' "$CFG" 2>/dev/null)"
  [ -n "$CUSTOM" ] && TERMS="$CUSTOM"
fi

SINKS='console\.(log|error|warn|info)|logger\.|logging\.|log\.(info|warn|error|debug)|print\(|println!|captureException|captureMessage|Sentry|track\('

HITS=$(git diff "$BASE"..HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' '*.java' '*.kt' \
  | grep -E '^\+' | grep -E "$SINKS" | grep -Eic "$TERMS" || true)

if [ "${HITS:-0}" -gt 0 ]; then
  echo "⚠️  PII→logs: $HITS added line(s) both log AND mention personal-data terms — check nothing sensitive is serialized (term list: piiTerms in proofgate.json)"
  exit 2
fi
echo "✅ PII→logs: no added lines logging personal-data terms"
exit 0
