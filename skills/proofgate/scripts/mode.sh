#!/usr/bin/env bash
# ProofGate — PROTOTYPE MODE. Fast, and impossible to forget you are in.
#
# Usage: mode.sh on | off | status
#
# The honest reason this exists: sometimes you are exploring, and the full ceremony —
# a red test before every edit, a claim behind every level — is genuinely the wrong
# price. A tool that refuses to admit that gets bypassed wholesale, and a bypassed gate
# protects nothing at all. So prototype mode is real: edit-guard and stop-guard stand
# down.
#
# The DANGER is not the mode. It is forgetting you are in it, and then reporting work
# done under relaxed rules as if it had been gated. That is the only failure this design
# treats as unacceptable, so the mode is loud in four places at once:
#
#   - a banner on EVERY prompt (hooks/prompt-hook.sh);
#   - a line at every session start, including after a compaction;
#   - `mode` in the verdict, so the machine-readable record carries it;
#   - claims recorded while it is on are capped at E1, and `claim.sh render` prefixes the
#     whole status with UNVERIFIED PROTOTYPE.
#
# And the push-guard does NOT stand down. Exploring is fine; shipping unproven work is
# the thing the tool exists to stop, and prototype mode is not a route around it.
#
# It also does not expire on its own. An auto-expiry would be the silent path: the mode
# would end quietly, at some moment nobody observed, and the state of any given piece of
# work would become a question of timing. You turn it off.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v pg_git_dir >/dev/null 2>&1 || { echo "mode: lib.sh not found" >&2; exit 1; }

F="$(pg_git_dir)/proofgate-mode"

case "${1:-status}" in
  on)
    printf '{"mode":"prototype","session":"%s","since":"%s"}\n' "${CLAUDE_SESSION_ID:-local}" "$(pg_now)" > "$F"
    echo "⚠️  PROTOTYPE MODE ON."
    echo "    Relaxed: edit-guard (no red test required), stop-guard (no verdict required to finish)."
    echo "    NOT relaxed: the push. Unproven work still cannot be pushed."
    echo "    Marked everywhere: a banner on every prompt, at every session start, \"mode\" in"
    echo "    the verdict, claims capped at E1, and the status block prefixed UNVERIFIED PROTOTYPE."
    echo "    It does not expire by itself — that would be the silent path. Leave with: mode.sh off"
    ;;
  off)
    if [ -f "$F" ]; then
      rm -f "$F"; echo "✅ prototype mode OFF — the full gate is back."
      echo "   Anything claimed while it was on was capped at E1. Re-record the claims that matter:"
      echo "     claim.sh add --claim \"...\" --level E3 --run \"<cmd>\" --expect \"<marker>\""
    else
      echo "▫️  prototype mode was not on"
    fi
    ;;
  status)
    if [ -f "$F" ]; then cat "$F"; else echo '{"mode":"normal"}'; fi
    ;;
  *) echo "usage: mode.sh on|off|status" >&2; exit 2 ;;
esac
