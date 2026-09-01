#!/usr/bin/env bash
# Guard: killing processes by name pattern instead of by PID.
#
# The scar: `pkill -f "verify.sh"` was run to stop a stale verification. It
# killed the one that had just been started too - the new run and the old one
# match the same name. A whole cycle was lost, and the output that came back
# looked like a crash rather than a self-inflicted kill, which is the expensive
# part: the next twenty minutes went to debugging a phantom.
#
# Anything that selects victims by pattern has this shape: it cannot tell your
# process from somebody else's, including your own future one. Kill the PID you
# wrote down, or ask the tool that owns the job to cancel it.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

BROAD='pkill|killall|kill[[:space:]]+-[0-9A-Za-z]+[[:space:]]+\$\(pgrep|kill[[:space:]]+\$\(pgrep|taskkill[[:space:]]+/IM'  # proofgate-allow

n=0
while IFS= read -r file; do n=$((n + 1)); done < <(
  pg_scan broad-process-kill "$BROAD" ':(exclude)*.md')

if [ "$n" -gt 0 ]; then
  echo "⚠️  broad-process-kill: $n added line(s) kill processes by name pattern. A pattern cannot tell your process from another - including the one you just started. Kill a recorded PID, or cancel through whatever owns the job."
  exit 2
fi
echo "✅ broad-process-kill: nothing kills by pattern"
exit 0
