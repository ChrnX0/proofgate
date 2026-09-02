#!/usr/bin/env bash
# ProofGate prompt-hook — a UserPromptSubmit hook whose only job is to make prototype
# mode impossible to forget.
#
# One line, on every turn. That repetition is the feature, not an oversight: a mode
# announced once, at the moment it was switched on, is a mode that will be forgotten by
# the time it matters — which is when work done under relaxed rules gets reported as if
# it had been gated. Everything else in ProofGate is designed to avoid nagging; this is
# the one place where nagging is the correct behaviour, because the cost of the silent
# path is a false status.
#
# The common case is a single file test and an exit, so it costs nothing when off.
set -uo pipefail

# shellcheck disable=SC2034
INPUT="$(cat 2>/dev/null || true)"
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0

{
  GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
  F="$GD/proofgate-mode"
  [ -f "$F" ] || exit 0
  SINCE="$(grep -o '"since":"[^"]*"' "$F" 2>/dev/null | head -1 | sed -e 's/^"since":"//' -e 's/"$//')"
  printf '⚠️  ProofGate PROTOTYPE MODE is ON (since %s). Nothing here is gated evidence: the edit-guard and stop-guard are relaxed and claims are capped at E1. The push is still blocked. Leave it with `/proofgate:prototype off` before reporting anything as done.\n' "${SINCE:-unknown}"
  exit 0
} 2>/dev/null || exit 0
exit 0
