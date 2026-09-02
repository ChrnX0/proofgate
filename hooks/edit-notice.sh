#!/usr/bin/env bash
# ProofGate edit-notice — a PostToolUse(Edit|Write|MultiEdit) hook that answers, at the
# moment of the edit, two questions the gate can only answer at the end:
#
#   1. does the project already KNOW something about this file? (anchored memory)
#   2. did what you just wrote trip a guard? (the diff guards, run live on that one path)
#
# Why bring the guards forward. The gate is deliberately a gate: it judges the finished
# diff. That timing is right for the verdict and wrong for the feedback. A secret pasted
# into a config, a `rejectUnauthorized: false` added to make a cert error go away, a
# `.only` left on a test — each is trivial to undo in the ten seconds after writing it,
# and each becomes a rewrite once twenty files depend on the shape around it. The guards
# are `git diff | grep`: milliseconds. There is no reason for that answer to wait.
#
# It NEVER blocks — PostToolUse cannot, and it should not want to. The edit already
# happened; this is information, delivered while it is still cheap to act on.
#
# Both halves are opt-in and independent: memory notices need `.proofgate/memory.jsonl`
# to exist, live guards need `liveGuards: true`. A hook that fires on every edit has to
# earn its latency, so the common path is one file test and an exit.
#
# Contract (Claude Code PostToolUse): stdin is the event JSON; stdout may add context.
# FAIL-OPEN and time-boxed.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0

{
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  { [ -f "$ROOT/proofgate.json" ] || [ -d "$ROOT/.proofgate" ]; } || exit 0

  MEM="$ROOT/.proofgate/memory.jsonl"
  HAS_MEM=0; [ -f "$MEM" ] && HAS_MEM=1

  PG="$ROOT/skills/proofgate/scripts/lib.sh"
  [ -f "$PG" ] || PG="$ROOT/.proofgate/lib.sh"
  [ -f "$PG" ] || PG="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../skills/proofgate/scripts" 2>/dev/null && pwd)/lib.sh"
  # shellcheck source=/dev/null
  [ -f "$PG" ] && PROOFGATE_CFG="$ROOT/proofgate.json" . "$PG" 2>/dev/null
  command -v cfg >/dev/null 2>&1 || exit 0

  LIVE=0; [ "$(cfg '.liveGuards' 2>/dev/null)" = "true" ] && LIVE=1
  [ "$HAS_MEM" = 0 ] && [ "$LIVE" = 0 ] && exit 0

  FP=""
  if command -v jq >/dev/null 2>&1; then
    FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    FP="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
 t=json.load(sys.stdin).get("tool_input",{});print(t.get("file_path") or t.get("path") or "")
except Exception:pass' 2>/dev/null)"
  elif command -v node >/dev/null 2>&1; then
    FP="$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const t=(JSON.parse(s).tool_input||{});process.stdout.write(t.file_path||t.path||"")}catch(e){}})' 2>/dev/null)"
  else
    exit 0
  fi
  [ -n "$FP" ] || exit 0

  # Paths arrive absolute; the ledgers and git speak repo-relative. Strip the prefix
  # using the PHYSICAL path of both, because on macOS they routinely differ: a repo
  # under `mktemp -d` sits at /var/folders/... while `git rev-parse --show-toplevel`
  # resolves the symlink to /private/var/folders/..., so a plain prefix strip leaves the
  # path absolute. `memory.sh recall` then matched nothing (anchors are repo-relative)
  # and the notice was silently empty — caught by the macOS CI matrix, on the one platform
  # this delivery declared as NOT TESTED. The live-guard half only "worked" because an
  # absolute pathspec made it scan the whole tree instead of the edited file.
  ROOT_P="$(cd "$ROOT" 2>/dev/null && pwd -P)"; ROOT_P="${ROOT_P:-$ROOT}"
  FP_DIR="$(cd "$(dirname "$FP")" 2>/dev/null && pwd -P)"
  if [ -n "$FP_DIR" ]; then REL="${FP_DIR}/$(basename "$FP")"; else REL="$FP"; fi
  REL="${REL#"$ROOT_P"/}"
  # Still absolute means the file is outside this repository — nothing here applies.
  case "$REL" in /*) exit 0 ;; esac

  SCRIPTS="$ROOT/skills/proofgate/scripts"
  [ -d "$SCRIPTS" ] || SCRIPTS="$ROOT/.proofgate"
  [ -f "$SCRIPTS/memory.sh" ] || SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../skills/proofgate/scripts" 2>/dev/null && pwd)"

  OUT=""

  if [ "$HAS_MEM" = 1 ] && [ -f "$SCRIPTS/memory.sh" ]; then
    R="$(cd "$ROOT" && bash "$SCRIPTS/memory.sh" recall "$REL" </dev/null 2>/dev/null | head -6)"
    [ -n "$R" ] && OUT="${OUT}The project has recorded facts about $REL:
$R
"
  fi

  # Live guards: the same guards the gate runs, pointed at this one file, against the
  # WORKING TREE rather than a committed range — the edit is not committed yet, which
  # is exactly why this is worth doing now.
  if [ "$LIVE" = 1 ] && [ -d "$SCRIPTS/guards.d" ]; then
    case "$REL" in .proofgate/*|*.lock) : ;; *)
      FIND="$(cd "$ROOT" && PROOFGATE_LIB="$PG" PROOFGATE_CFG="$ROOT/proofgate.json" \
              PROOFGATE_WORKTREE=1 PROOFGATE_PATHSPEC="$REL" PROOFGATE_BASE="HEAD" \
              sh -c 'for g in "$0"/*.sh; do [ -f "$g" ] || continue
                       out="$(bash "$g" 2>/dev/null)"; code=$?
                       [ "$code" != 0 ] && printf "%s\n" "$out"
                     done' "$SCRIPTS/guards.d" 2>/dev/null | grep -E '^(❌|⚠️)' | head -5)"
      [ -n "$FIND" ] && OUT="${OUT}A guard fires on what you just wrote in $REL — cheaper to fix now than at the gate:
$FIND
"
      ;;
    esac
  fi

  [ -n "$OUT" ] || exit 0
  if command -v pg_json_escape >/dev/null 2>&1; then
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(pg_json_escape "ProofGate: $OUT")"
  else
    printf 'ProofGate: %s\n' "$OUT"
  fi
  exit 0
} 2>/dev/null || exit 0
exit 0
