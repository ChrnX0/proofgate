#!/usr/bin/env bash
# ProofGate edit-guard — a PreToolUse(Edit|Write|MultiEdit) hook that refuses to edit
# source while an OPEN bugfix hypothesis has no failing test behind it.
#
# The scar it encodes is the most expensive one in agentic development: the fix that
# fixed nothing. It happens because the order of work is inverted. The agent forms an
# idea about the cause, edits the code, runs the suite, sees green, and reports the bug
# fixed — but the suite was green before the edit too, so the run proved only that
# nothing else broke. Nobody ever established that the bug was reachable by a test at
# all. Days later the bug is still there, and the "fix" is now load-bearing code that
# nobody understands the purpose of.
#
# The counter-proof has to come FIRST, and "first" is the part a prompt cannot enforce,
# because by the time the agent is editing, the intention to write the test later is
# completely sincere. So this hook holds the door: with an open `--kind bugfix`
# hypothesis and no red-test claim for it, an edit to a non-test source file is blocked
# with the exact command to run.
#
# Deliberately OPT-IN (`editGuard: true`) and OFF by default. It is the most intrusive
# thing in this repo — it interrupts the moment of writing code — and a team that has
# not chosen it will route around it, which costs more than it saves.
#
# What it CANNOT do, said plainly: an edit made through Bash (`sed -i`, a heredoc)
# never reaches this hook. It raises the cost of skipping the counter-proof; it does
# not make skipping impossible. The audit log (3.0) is what sees the other path.
#
# Contract (Claude Code PreToolUse): stdin is the event JSON; exit 0 allows, exit 2
# blocks and feeds stderr back to the agent. FAIL-OPEN by construction.
#
# Escape hatches: PROOFGATE_HOOK_OFF=1 · editGuard:false/absent · prototype mode ·
# `hypothesis.sh park <id>` when the investigation is genuinely on hold.
set -uo pipefail

# NOTE on the fail-open wrapper below. Everything is wrapped in `{ ... } 2>/dev/null`
# so that a broken guard can never wedge the agent — but that same redirect silently ate
# this hook's own block message for four releases. The contract says "exit 2 blocks and
# feeds stderr back to the agent"; what the agent actually received was a bare refusal
# with no reason, which is the exact silent failure this project exists to forbid.
# So the deliberate output goes to fd 3, dup'd from the real stderr BEFORE the wrapper,
# where the noise-suppressing redirect cannot reach it.
exec 3>&2
INPUT="$(cat 2>/dev/null || true)"
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0

{
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
  HYP="$GD/proofgate-hypotheses.jsonl"
  # Cheap prefilter FIRST: no hypothesis ledger, nothing to enforce. This fires on
  # every single edit, so the common path must be one file test and out.
  [ -f "$HYP" ] || exit 0
  # Prototype mode relaxes this deliberately — it is announced every turn and every
  # session start, and claims made in it are capped, so it cannot launder evidence.
  [ -f "$GD/proofgate-mode" ] && exit 0

  { [ -f "$ROOT/proofgate.json" ] || [ -d "$ROOT/.proofgate" ]; } || exit 0
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
  command -v cfg >/dev/null 2>&1 || exit 0
  [ "$(cfg '.editGuard' 2>/dev/null)" = "true" ] || exit 0

  # Extract tool_input.file_path — jq → python3 → node, same chain as push-guard.
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

  # Tests, docs, config and ProofGate's own files are always allowed — the whole point
  # is to make writing the test the available move, so blocking the test would be
  # self-defeating.
  case "$FP" in
    */.proofgate/*|*/.proofgateignore) exit 0 ;;
    *.md|*.mdx|*.txt|*.rst|*.json|*.yml|*.yaml|*.toml|*.lock) exit 0 ;;
  esac
  printf '%s' "$FP" | grep -Eq '(\.test\.|\.spec\.|__tests__|_test\.|(^|/)tests?/|(^|/)spec/)' && exit 0

  # Is there an open bugfix hypothesis with no red test behind it?
  # Status is the LAST event for an id, so the fold has to run over the whole file.
  OPEN_BUGFIX="$(awk '
    match($0, /"id":"[^"]*"/)    { id = substr($0, RSTART + 6, RLENGTH - 7) }
    match($0, /"event":"[^"]*"/) { ev = substr($0, RSTART + 9, RLENGTH - 10) }
    match($0, /"kind":"[^"]*"/)  { kd = substr($0, RSTART + 8, RLENGTH - 9) }
    { st[id] = ev; kind[id] = (kind[id] == "" ? kd : kind[id]) }
    END { for (i in st) if (kind[i] == "bugfix" && (st[i] == "open" || st[i] == "reopen" || st[i] == "experiment")) { print i; exit } }
  ' "$HYP" 2>/dev/null)"
  [ -n "$OPEN_BUGFIX" ] || exit 0

  CLAIMS="$GD/proofgate-claims.jsonl"
  if [ -f "$CLAIMS" ] && grep -q "\"kind\":\"red-test\"" "$CLAIMS" 2>/dev/null; then
    grep "\"hypothesis\":\"$OPEN_BUGFIX\"" "$CLAIMS" 2>/dev/null | grep -q '"kind":"red-test"' && exit 0
  fi

  HTXT="$(grep "\"id\":\"$OPEN_BUGFIX\"" "$HYP" 2>/dev/null | head -1 | grep -o '"hypothesis":"[^"]*"' | sed -e 's/^"hypothesis":"//' -e 's/"$//')"
  HCMD="$(grep "\"id\":\"$OPEN_BUGFIX\"" "$HYP" 2>/dev/null | head -1 | grep -o '"cmd":"[^"]*"' | sed -e 's/^"cmd":"//' -e 's/"$//')"
  {
    echo "ProofGate: edit blocked — $OPEN_BUGFIX is an open bugfix hypothesis (\"$HTXT\") with no failing test behind it."
    echo
    echo "Write the counter-proof first. A suite that was green before your edit and green after it"
    echo "has proven that nothing else broke — not that the bug is gone. Record the RED run:"
    echo
    echo "    claim.sh add --kind red-test --hypothesis $OPEN_BUGFIX --run \"${HCMD:-<the test that fails today>}\""
    echo
    echo "It is refused if that command passes, which is the point: a test that was never red has"
    echo "never shown it can see this bug. Then edit, then:"
    echo
    echo "    claim.sh add --kind green-test --same-as <red-id> --run \"<the SAME command>\""
    echo
    echo "Not a bugfix after all? hypothesis.sh park $OPEN_BUGFIX. Turn the guard off: editGuard:false."
  } >&3
  exit 2
} 2>/dev/null || exit 0
exit 0
