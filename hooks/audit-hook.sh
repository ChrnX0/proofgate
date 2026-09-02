#!/usr/bin/env bash
# ProofGate audit-hook — a PostToolUse(Bash) chronology of what ran.
#
# It records commands, NOT evidence, and the distinction is the reason this file is
# short. A PostToolUse hook is handed the tool's input and response; it is not handed a
# reliable exit code, so every entry stores `exit: null`. A chronology that pretended to
# carry exit codes would be worse than none — it would look like evidence while being
# unable to distinguish a command that passed from one that failed, which is exactly the
# confusion the rest of this project exists to remove. Evidence with a trustworthy exit
# code comes from claim.sh and experiment.sh, which run the command themselves.
#
# What it is genuinely for: the edit-guard can be walked around by editing through Bash
# (`sed -i`, a heredoc), and `.git/` is writable, so a ledger can be hand-written. Neither
# is preventable by a hook. Both leave a trace HERE, and the sealed bundle carries the
# segment of that trace which the claims rest on. Tamper-evident, not tamper-proof.
#
# OPT-IN (`audit: true`) and off by default, for two reasons: it fires on every Bash call,
# and command lines are one of the likeliest places for a credential to be sitting. The
# sealed segment is filtered to claim-linked commands and redacted, but the local log is
# raw — which is why you choose to keep it.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0

{
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  { [ -f "$ROOT/proofgate.json" ] || [ -d "$ROOT/.proofgate" ]; } || exit 0
  PG="$ROOT/skills/proofgate/scripts/lib.sh"
  [ -f "$PG" ] || PG="$ROOT/.proofgate/lib.sh"
  [ -f "$PG" ] || PG="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../skills/proofgate/scripts" 2>/dev/null && pwd)/lib.sh"
  # shellcheck source=/dev/null
  [ -f "$PG" ] && PROOFGATE_CFG="$ROOT/proofgate.json" . "$PG" 2>/dev/null
  command -v cfg >/dev/null 2>&1 || exit 0
  [ "$(cfg '.audit' 2>/dev/null)" = "true" ] || exit 0

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

  GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
  F="$GD/proofgate-audit.jsonl"
  # Rotate rather than grow without bound; this appends on every Bash call.
  if [ -f "$F" ] && [ "$(wc -c < "$F" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    mv "$F" "$F.1" 2>/dev/null || true
  fi
  SHORT="$(printf '%s' "$CMD" | cut -c1-512)"
  pg_lock audit || exit 0
  printf '{"ts":"%s","session":"%s","cmd":"%s","cmd_sha":"%s","exit":null,"out_sha":""}\n' \
    "$(pg_now)" "${CLAUDE_SESSION_ID:-local}" "$(pg_json_escape "$SHORT")" "$(printf '%s' "$CMD" | pg_sha1)" \
    >> "$F" 2>/dev/null || true
  pg_unlock audit
  exit 0
} 2>/dev/null || exit 0
exit 0
