#!/usr/bin/env bash
# Guard: this copy of the gate holds guards or fixes that upstream has never seen.
#
# The scar: the rule "a mistake that a script would catch becomes a guard in the
# proofgate repo and goes up by PR" was written in a project's CLAUDE.md — prose, level 2 of
# the SKILL's own ladder. Measured 2026-09-30: the heaviest user of this tool held six guards,
# a `cfg` that stops swallowing `false` (its documented emergency switch never worked), a
# `pg_match` that cut the gate from ~8 min to 22 s and two false-positive fixes — committed
# and tested there, absent here. "I will send it up later" is an instruction nobody's
# process contains, and the installer used to erase the local guard on the next upgrade.
#
# So the gate says it, every run, until it is answered: `upstream.sh diff|send` returns the
# lesson, `upstream.keepLocal` in proofgate.json declares a file project-specific ON PURPOSE.
# ONE aggregated line; silent when this copy has no lock (installed before the lock existed,
# or not a vendored copy) — it cannot tell what was learned, and guessing would be the nag.
# Exit: 0 = clean · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# shellcheck disable=SC2034
BASE="${PROOFGATE_BASE:?}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/upstream.lock" ] || { echo "✅ upstream-drift: no upstream.lock here — not tracking what this copy learns (install.sh writes one)"; exit 0; }
[ -f "$HERE/upstream.sh" ] || { echo "✅ upstream-drift: upstream.sh missing — guard skipped"; exit 0; }

ROWS="$(PG_LOCAL_DIR="$HERE" bash "$HERE/upstream.sh" status --quiet 2>/dev/null || true)"
[ -n "$ROWS" ] || { echo "✅ upstream-drift: nothing here that upstream lacks"; exit 0; }

N="$(printf '%s\n' "$ROWS" | grep -c . || true)"
NEW="$(printf '%s\n' "$ROWS" | grep -c '^new' || true)"
NAMES="$(printf '%s\n' "$ROWS" | awk -F'\t' '{ n = $2; sub(/^.*\//, "", n); printf "%s%s", (NR > 1 ? ", " : ""), n }')"
echo "⚠️  upstream-drift: $N file(s) here differ from what the gate shipped ($NEW added, $((N - NEW)) changed): $NAMES"
echo "    A lesson that stays in one project protects that project only. Send it back —"
echo "    \`bash .proofgate/upstream.sh diff <proofgate clone>\` then \`… send <clone>\` — or, when it is"
echo "    project-specific on purpose, list the file under upstream.keepLocal in proofgate.json."
exit 2
