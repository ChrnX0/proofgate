#!/usr/bin/env bash
# ProofGate — run a hypothesis somewhere it cannot hurt anything.
#
# Usage:
#   experiment.sh <h-id> [--dirty] [--in-place] [--timeout N] -- <cmd...>
#   experiment.sh --parallel <h-id>::<cmd> <h-id>::<cmd> ...
#   experiment.sh clean                      # remove leftover experiment worktrees
#
# WHY a worktree instead of just running the command:
#
# Testing an idea usually means changing something — a flag, a version, a line — running,
# and changing it back. "Changing it back" is where this goes wrong. Three hypotheses in
# a row leave a working tree nobody can characterise: some edits reverted, some not, one
# half-applied, and the next test result is about a state that was never designed. The
# classic ending is a "fix" that works only because of a leftover from experiment two.
#
# So each experiment gets its own `git worktree`, runs there, and is removed. The result
# is recorded against the hypothesis by THIS script — not typed afterwards by whoever
# remembers what happened — which is the same rule as the claims ledger, for the same
# reason.
#
# `--parallel` is what makes the isolation pay for itself: several ideas can be tested at
# once, because they no longer share a directory. Sequential testing of independent
# hypotheses was never a requirement, only a consequence of having one working tree.
#
# `--in-place` exists for the cases a worktree cannot serve (a running dev server, a
# native toolchain that will not relocate). It is honest about the cost: the tree hash is
# taken before and after, and a mutation is recorded as a `tree-mutated` degradation on
# the result, because a result produced by a run that changed the tree is a result about
# a state that no longer exists.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "experiment: lib.sh not found" >&2; exit 1; }

GD="$(pg_git_dir)"; CD="$(pg_common_dir)"
LEDGER="$GD/proofgate-hypotheses.jsonl"
EXPDIR="$CD/proofgate-exp"
TMO="$(cfg '.experiment.timeoutSeconds')"; TMO="${TMO:-$(cfg '.timeoutSeconds')}"; TMO="${TMO:-900}"

die() { echo "❌ experiment: $1" >&2; exit 2; }
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout --foreground "$TMO" "$@"; else "$@"; fi; }

# Dependency directories are enormous and not worth copying per experiment; symlinking
# them keeps a worktree usable without turning every idea into a `npm install`.
link_deps() {
  local wt="$1" d
  local links; links="$(cfg_list '.experiment.link')"
  [ -n "$links" ] || links="node_modules
.venv
venv
target
vendor
.gradle"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -e "$PWD/$d" ] && [ ! -e "$wt/$d" ] && ln -s "$PWD/$d" "$wt/$d" 2>/dev/null || true
  done <<EOF
$links
EOF
}

run_one() { # run_one <h-id> <dirty> <in_place> <cmd...>
  local id="$1" dirty="$2" in_place="$3"; shift 3
  local cmd="$*"
  [ -n "$id" ] || die "an experiment belongs to a hypothesis: pass its id"
  grep -q "\"id\":\"$id\"" "$LEDGER" 2>/dev/null || die "no hypothesis $id (open one first: hypothesis.sh open ...)"
  [ -n "$cmd" ] || die "nothing to run — put the command after --"

  local degr="" out t0 t1 code=0 wt="" tree_before=""
  if [ "$in_place" = 1 ]; then
    tree_before="$(pg_tree_hash)"
    t0="$(pg_epoch)"
    out="$(with_timeout bash -c "$cmd" 2>&1)"; code=$?
    t1="$(pg_epoch)"
    [ "$(pg_tree_hash)" != "$tree_before" ] && degr='{"code":"tree-mutated","detail":"the run changed the working tree; this result describes a state that no longer exists"}'
  else
    mkdir -p "$EXPDIR" 2>/dev/null
    # mktemp, not "$id-$(pg_epoch)-$$": two --parallel jobs starting in the same second
    # share the parent's PID, so the composed name collided and the second worktree
    # failed to create. Uniqueness has to be atomic, not merely likely.
    wt="$(mktemp -d "$EXPDIR/$id-XXXXXX" 2>/dev/null)" || die "could not allocate an experiment directory"
    rmdir "$wt" 2>/dev/null || true
    # The worktree is removed on ANY exit path. A failed experiment that leaves a
    # worktree behind is a slow leak that ends with `git worktree list` unreadable.
    trap 'git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"' EXIT INT TERM
    git worktree add --detach "$wt" HEAD >/dev/null 2>&1 || die "could not create a worktree (use --in-place if this repo cannot host one)"
    if [ "$dirty" = 1 ]; then
      # Carry the uncommitted work across: without this, an experiment about the change
      # you are making would run against the code as it was before you made it.
      git diff HEAD 2>/dev/null | ( cd "$wt" && git apply --allow-empty - 2>/dev/null ) || \
        degr='{"code":"dirty-not-applied","detail":"uncommitted changes did not apply cleanly to the worktree"}'
      git ls-files -o --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' f; do
        mkdir -p "$wt/$(dirname "$f")" 2>/dev/null; cp "$f" "$wt/$f" 2>/dev/null || true
      done
    fi
    link_deps "$wt"
    t0="$(pg_epoch)"
    out="$(cd "$wt" && with_timeout bash -c "$cmd" 2>&1)"; code=$?
    t1="$(pg_epoch)"
    git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    trap - EXIT INT TERM
  fi

  [ "$code" = 124 ] && degr="${degr:+$degr,}{\"code\":\"timed-out\",\"detail\":\"killed after ${TMO}s\"}"
  command -v timeout >/dev/null 2>&1 || degr="${degr:+$degr,}{\"code\":\"no-timeout\",\"detail\":\"coreutils timeout not available; the run was unbounded\"}"
  printf '%s' "$out" | grep -Eq 'Cannot find module|ModuleNotFoundError|command not found|No such file or directory' && \
    degr="${degr:+$degr,}{\"code\":\"missing-deps\",\"detail\":\"the isolated tree may be missing dependencies (experiment.link)\"}"

  local body
  body="{\"id\":\"$id\",\"ts\":\"$(pg_now)\",\"event\":\"experiment\",\"kind\":\"\",\"symptom\":\"\",\"escalated\":false,\"strikes\":0"
  body="$body,\"hypothesis\":\"\",\"prediction\":\"\",\"cmd\":\"$(pg_json_escape "$cmd")\",\"norm\":\"\""
  body="$body,\"observed\":\"$(pg_json_escape "$(printf '%s' "$out" | head -3 | tr '\n' ' ' | cut -c1-200)")\",\"exit\":$code"
  body="$body,\"out_sha\":\"$(printf '%s' "$out" | pg_sha1)\",\"duration_ms\":$(( (t1 - t0) * 1000 ))"
  body="$body,\"isolation\":\"$([ "$in_place" = 1 ] && echo in-place || echo worktree)\",\"degradations\":[$degr]"
  body="$body,\"anchors\":[],\"head_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"via\":\"experiment.sh\""
  pg_ledger_append "$LEDGER" "$body"

  echo "▫️  $id experiment: exit $code ($([ "$in_place" = 1 ] && echo in-place || echo worktree), $(( t1 - t0 ))s)"
  printf '%s\n' "$out" | head -10 | sed 's/^/     /'
  [ -n "$degr" ] && printf '     declared: %s\n' "$(printf '%s' "$degr" | grep -o '"code":"[^"]*"' | sed -e 's/"code":"//g' -e 's/"//g' | tr '\n' ' ')"
  # Never auto-confirms. An experiment produces an observation; deciding what it MEANS
  # is the judgment this whole tool refuses to fake.
  echo "     → this is an observation, not a verdict. Close the hypothesis yourself:"
  echo "       hypothesis.sh refute $id --observed \"...\"   |   confirm $id --run \"<the proof>\""
  return 0
}

cmd_parallel() {
  [ $# -gt 0 ] || die "--parallel needs <h-id>::<cmd> pairs"
  local pids="" i=0 outs=""
  for spec in "$@"; do
    case "$spec" in *::*) ;; *) die "expected <h-id>::<cmd>, got '$spec'" ;; esac
    local id="${spec%%::*}" cmd="${spec#*::}"
    i=$((i + 1))
    local of; of="$(mktemp)"; outs="$outs $of"
    ( run_one "$id" 0 0 "$cmd" >"$of" 2>&1 ) &
    pids="$pids $!"
  done
  # `wait -n` is bash 4; collect the pids and wait for each in turn.
  for p in $pids; do wait "$p" 2>/dev/null || true; done
  for of in $outs; do cat "$of"; rm -f "$of"; done
  echo "✅ $i experiment(s) finished — each in its own worktree, so none of them saw the others"
}

cmd_clean() {
  [ -d "$EXPDIR" ] || { echo "✅ no experiment worktrees"; return 0; }
  local n=0
  for d in "$EXPDIR"/*; do
    [ -d "$d" ] || continue
    git worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"
    n=$((n + 1))
  done
  git worktree prune >/dev/null 2>&1 || true
  echo "✅ removed $n experiment worktree(s)"
}

case "${1:-}" in
  clean) cmd_clean ;;
  --parallel) shift; cmd_parallel "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    ID="$1"; shift
    DIRTY=0 INPLACE=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --dirty) DIRTY=1 ;;
        --in-place) INPLACE=1 ;;
        --timeout) shift; TMO="${1:-$TMO}" ;;
        --) shift; break ;;
        *) die "unknown flag: $1" ;;
      esac
      shift
    done
    run_one "$ID" "$DIRTY" "$INPLACE" "$@"
    ;;
esac
