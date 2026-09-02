#!/usr/bin/env bash
# ProofGate session-hook — a SessionStart hook that re-injects what the context just
# forgot: open hypotheses, refuted ones, unresolved lessons, and any mode left on.
#
# Matchers: startup · resume · compact. The third is the one that matters.
#
# The failure this exists for is specific and expensive. A long investigation rules
# things out — "checked the reflog, no reset"; "no cache step in this pipeline at all" —
# and those refutations are the most valuable thing produced, because each one is a
# whole branch of the search space closed. Then the context is compacted. The summary
# keeps the code and the goal, and drops the negative results, because they read like
# noise: nothing happened. The very next turn proposes the dead explanation again, and
# it is MORE convincing the second time, since nothing visible contradicts it.
#
# The ledgers already survive on disk (hypothesis.sh, memory.sh). This hook is what
# puts them back in front of the model after a compaction, so "already ruled out" is a
# fact in context rather than a file nobody thought to read.
#
# Contract (Claude Code SessionStart): stdin carries the event JSON; stdout is added to
# the session context — either as plain text, or as JSON with
# hookSpecificOutput.additionalContext. FAIL-OPEN and cheap: the common case is two
# file tests and an exit.
#
# Escape hatches: PROOFGATE_HOOK_OFF=1 · the repo simply not adopting ProofGate.
set -uo pipefail

# Drain stdin: the event JSON is not needed (the matcher already told us why we were
# invoked) but leaving it unread can hand the caller a broken pipe.
# shellcheck disable=SC2034
INPUT="$(cat 2>/dev/null || true)"
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0

{
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  { [ -f "$ROOT/proofgate.json" ] || [ -d "$ROOT/.proofgate" ]; } || exit 0
  GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0

  # Cheap prefilter: with no ledger and no mode file there is nothing to say, and this
  # runs on every session start.
  HYP="$GD/proofgate-hypotheses.jsonl"
  MODE="$GD/proofgate-mode"
  LESSONS="$ROOT/.proofgate/lessons.jsonl"
  MEM="$ROOT/.proofgate/memory.jsonl"
  { [ -f "$HYP" ] || [ -f "$MODE" ] || [ -f "$LESSONS" ] || [ -f "$MEM" ]; } || exit 0

  # lib.sh, in order: this repo's own source · what install.sh vendored · the copy that
  # ships INSIDE this plugin. The third fallback matters: installed as a Claude Code
  # plugin without ever running install.sh, the first two are absent, `cfg` is undefined,
  # and every hook quietly exits 0 — a guard that silently does nothing is worse than no
  # guard, because the repo believes it is protected.
  PG="$ROOT/skills/proofgate/scripts/lib.sh"
  [ -f "$PG" ] || PG="$ROOT/.proofgate/lib.sh"
  [ -f "$PG" ] || PG="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../skills/proofgate/scripts" 2>/dev/null && pwd)/lib.sh"
  # shellcheck source=/dev/null
  [ -f "$PG" ] && PROOFGATE_CFG="$ROOT/proofgate.json" . "$PG" 2>/dev/null
  command -v pg_json_escape >/dev/null 2>&1 || exit 0

  # Same three-step lookup as lib.sh above, and for the same reason: installed as a
  # plugin without vendoring, the repo has neither path and this hook would find no
  # hypothesis.sh to ask — producing an empty, entirely silent injection.
  SCRIPTS="$ROOT/skills/proofgate/scripts"
  [ -d "$SCRIPTS" ] || SCRIPTS="$ROOT/.proofgate"
  [ -f "$SCRIPTS/hypothesis.sh" ] || SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../skills/proofgate/scripts" 2>/dev/null && pwd)"

  BODY=""
  add() { BODY="${BODY}$1
"; }

  # A prototype session that outlived the reason for it is the silent path this whole
  # design forbids, so it is announced first and every time.
  if [ -f "$MODE" ]; then
    add "⚠️  ProofGate PROTOTYPE MODE is ON (since $(grep -o '\"since\":\"[^\"]*\"' "$MODE" 2>/dev/null | head -1 | sed -e 's/^\"since\":\"//' -e 's/\"$//')). Nothing produced in this mode is gated evidence; claims are capped at E1 and the push is still blocked. Leave it with: /proofgate:prototype off"
  fi

  if [ -f "$HYP" ] && [ -f "$SCRIPTS/hypothesis.sh" ]; then
    BRIEF="$(bash "$SCRIPTS/hypothesis.sh" brief </dev/null 2>/dev/null | head -40)"
    [ -n "$BRIEF" ] && add "$BRIEF"
  fi

  if [ -f "$MEM" ] && [ -f "$SCRIPTS/memory.sh" ]; then
    RECALL="$(bash "$SCRIPTS/memory.sh" recall --changed </dev/null 2>/dev/null | head -20)"
    [ -n "$RECALL" ] && add "PROJECT MEMORY anchored to files in this change:
$RECALL"
  fi

  if [ -f "$LESSONS" ]; then
    OPEN_L="$(grep '"event":"open"' "$LESSONS" 2>/dev/null | while IFS= read -r l; do
      lid="$(printf '%s' "$l" | grep -o '"id":"[^"]*"' | head -1 | sed -e 's/^"id":"//' -e 's/"$//')"
      grep -q "\"event\":\"resolve\".*\"id\":\"$lid\"\|\"id\":\"$lid\".*\"event\":\"resolve\"" "$LESSONS" 2>/dev/null || \
        printf '  %s %s\n' "$lid" "$(printf '%s' "$l" | grep -o '"text":"[^"]*"' | head -1 | sed -e 's/^"text":"//' -e 's/"$//')"
    done | head -10)"
    [ -n "$OPEN_L" ] && add "UNRESOLVED LESSONS (each one is a scar with no guard behind it yet):
$OPEN_L"
  fi

  [ -n "$BODY" ] || exit 0
  BODY="ProofGate — state that survived the context, not the conversation:
$BODY"

  # Prefer the documented JSON shape; fall back to plain stdout, which SessionStart
  # also accepts. Either way a parse failure must not break the session start.
  if command -v pg_json_escape >/dev/null 2>&1; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(pg_json_escape "$BODY")"
  else
    printf '%s\n' "$BODY"
  fi
  exit 0
} 2>/dev/null || exit 0
exit 0
