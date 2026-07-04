#!/usr/bin/env bash
# ProofGate push-guard — a PreToolUse(Bash) hook that refuses `git push` unless a
# FRESH, PASSING verdict exists for the current HEAD.
#
# Why a PreToolUse hook and not a git pre-push hook: the adversary here is the
# AGENT, and a git pre-push hook is trivially skipped with `git push --no-verify`
# (a real, reported failure mode — anthropics/claude-code#40117). This hook sees
# the RAW command the agent is about to run, BEFORE git does, so `--no-verify`
# cannot slip the push past it — and we flag the bypass attempt explicitly.
#
# Contract (Claude Code PreToolUse): reads the event JSON on stdin; exit 0 allows,
# exit 2 blocks and feeds stderr back to the agent. It is FAIL-OPEN by construction:
# any parse error, missing tool, or unexpected state ends in `exit 0` — a broken
# guard must never wedge the agent.
#
# Escape hatches: PROOFGATE_HOOK_OFF=1 (env) · "pushGuard": false (proofgate.json).
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

# 0) Cheap prefilter — this hook fires on EVERY Bash call; the common path is two
#    builtins and out. If the payload can't possibly be a push, leave immediately.
case "$INPUT" in *push*) ;; *) exit 0 ;; esac
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0

# Everything below is wrapped so any failure falls through to `exit 0` (fail-open).
{
  # 1) Extract tool_input.command — jq → python3 → node. No parser → fail-open.
  CMD=""
  if command -v jq >/dev/null 2>&1; then
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    CMD="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception:pass' 2>/dev/null)"
  elif command -v node >/dev/null 2>&1; then
    CMD="$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write((JSON.parse(s).tool_input||{}).command||"")}catch(e){}})' 2>/dev/null)"
  else
    exit 0
  fi
  [ -n "$CMD" ] || exit 0

  # 2) Is this actually a `git push`? (allow `git` with any global flags before push)
  printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:](])git([[:space:]]+-[-[:alnum:]=]+)*[[:space:]]+push([[:space:]]|$)' || exit 0

  # 3) Opt-in: only guard repos that adopted ProofGate.
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  { [ -f "$ROOT/proofgate.json" ] || [ -d "$ROOT/.proofgate" ]; } || exit 0
  PG="$ROOT/skills/proofgate/scripts/lib.sh"; [ -f "$PG" ] || PG="$ROOT/.proofgate/lib.sh"
  # shellcheck source=/dev/null
  [ -f "$PG" ] && PROOFGATE_CFG="$ROOT/proofgate.json" . "$PG" 2>/dev/null
  if command -v cfg >/dev/null 2>&1; then
    [ "$(cfg '.pushGuard' 2>/dev/null)" = "false" ] && exit 0
  fi

  # 4) Anti-bypass: block AND name the attempt (the differentiator vs a git hook).
  if printf '%s' "$CMD" | grep -Eq -- '--no-verify|core\.hooksPath'; then
    echo "ProofGate: push blocked — this command tries to bypass verification (--no-verify / core.hooksPath). Run the gate and push cleanly, or set pushGuard:false in proofgate.json if you truly mean to." >&2
    exit 2
  fi

  # 5) Freshness: a verdict whose sha == HEAD and pass == true.
  GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
  V="$GD/proofgate-verdict.json"
  HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
  if [ -f "$V" ]; then
    VSHA="$(sed -n 's/.*"sha":"\([0-9a-f]\{7,40\}\)".*/\1/p' "$V" 2>/dev/null | head -1)"
    if [ "$VSHA" = "$HEAD_SHA" ] && grep -q '"pass":true' "$V" 2>/dev/null; then
      exit 0   # fresh + passing → let the push through
    fi
  fi

  # 6) Block with an actionable reason.
  GATE="bash .proofgate/verify.sh"; [ -f "$ROOT/.proofgate/verify.sh" ] || GATE="the ProofGate skill / verify.sh"
  echo "ProofGate: push blocked — no fresh passing verdict for HEAD ${HEAD_SHA:0:7}. Run \`$GATE\` (it must pass), then push. Bypass: pushGuard:false in proofgate.json, or PROOFGATE_HOOK_OFF=1." >&2
  exit 2
} 2>/dev/null || exit 0
exit 0
