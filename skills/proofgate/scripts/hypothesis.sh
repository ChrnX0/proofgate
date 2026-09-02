#!/usr/bin/env bash
# ProofGate — the HYPOTHESIS LEDGER. What you already tried, and what it ruled out.
#
# Usage:
#   hypothesis.sh open --kind bugfix|feature|diagnosis --hypothesis "<mechanism>"
#                       [--prediction "<what must exist if true>"] [--cmd "<command that reveals it>"]
#                       [--symptom <tag>] [--anchor path[:line]]...
#   hypothesis.sh refute  <id> (--run "<cmd>" | --observed "<what you saw>")
#   hypothesis.sh confirm <id> (--run "<cmd>" | --observed "<what you saw>")
#   hypothesis.sh reopen  <id> --new-evidence "<what changed>"
#   hypothesis.sh park <id> · list [--open|--refuted] · show <id> · gc [--keep <n>]
#
# WHY:
#
# The SKILL already teaches the loop — hypothesis, falsifiable prediction, the command
# that reveals the mark, read the result. What it cannot do is make the RESULT survive.
# A long session gets compacted; the summary keeps the code and drops "I already checked
# the reflog and there was no reset". So the same dead explanation gets proposed again,
# investigated again, and paid for again — and the second time it is even more
# convincing, because nothing in the visible context contradicts it.
#
# So refutations live on disk, not in the conversation, and a SessionStart hook injects
# the open and refuted ones back after every compaction (hooks/session-hook.sh).
#
# Two mechanisms sit on top of that:
#
#   - Re-opening a hypothesis whose TEXT was already refuted is refused. The check is
#     exact-match on a normalized form, so re-wording still gets through; that limit is
#     declared rather than hidden, and the re-injection is what covers it — the agent
#     reads the refuted list every time the context restarts.
#
#   - STRIKE ESCALATION. The SKILL's rule that the bar INVERTS for external causes has
#     never had a mechanism. Now: refutations are counted per `--symptom`, and once the
#     same symptom has survived N explanations (default 2), the next hypothesis on it is
#     marked `escalated`. impact.sh reads that and forces `skeptic_required` — the third
#     guess about the same stubborn symptom is exactly where an invented culprit gets
#     written down and hardens into folklore.
#
# The file is an append-only EVENT log: status is the last event for an id. Nothing is
# ever rewritten, so "we thought X, then ruled it out, then reopened it with new
# evidence" stays legible as a sequence instead of collapsing into a final answer.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "hypothesis: lib.sh not found" >&2; exit 1; }

GD="$(pg_git_dir)"
LEDGER="$GD/proofgate-hypotheses.jsonl"
TMO="$(cfg '.timeoutSeconds')"; TMO="${TMO:-900}"
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout --foreground "$TMO" "$@"; else "$@"; fi; }
STRIKES="$(cfg '.hypothesis.strikeThreshold')"; STRIKES="${STRIKES:-2}"

die() { echo "❌ hypothesis: $1" >&2; exit 2; }
fld() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed -e "s/^\"$2\":\"//" -e 's/"$//'; }

# Normalized text, so "A daemon resets the repo" and "a  daemon   resets the repo"
# are the same hypothesis. Case and whitespace only — re-wording is NOT caught, and
# the docs say so rather than implying a semantic check.
norm_of() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' | pg_sha1; }

# Status = the last event recorded for an id (append-only log, folded with awk).
status_of() {
  awk -v id="$1" '
    index($0, "\"id\":\"" id "\"") {
      if (match($0, /"event":"[^"]*"/)) st = substr($0, RSTART + 9, RLENGTH - 10)
    }
    END { print (st == "" ? "none" : st) }' "$LEDGER" 2>/dev/null
}
row_of() { grep "\"id\":\"$1\"" "$LEDGER" 2>/dev/null | head -1; }

# open|reopen|experiment mean "live"; refute|confirm|park close it.
is_open() { case "$(status_of "$1")" in open|reopen|experiment) return 0 ;; *) return 1 ;; esac; }

cmd_open() {
  local kind="diagnosis" hyp="" pred="" cmd="" symptom="" anchors=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) shift; kind="${1:-}" ;;
      --hypothesis) shift; hyp="${1:-}" ;;
      --prediction) shift; pred="${1:-}" ;;
      --cmd) shift; cmd="${1:-}" ;;
      --symptom) shift; symptom="${1:-}" ;;
      --anchor) shift; anchors="$anchors ${1:-}" ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done
  case "$kind" in bugfix|feature|diagnosis) ;; *) die "unknown --kind '$kind' (bugfix|feature|diagnosis)" ;; esac
  [ -n "$hyp" ] || die "--hypothesis is required: state the MECHANISM in one sentence, not the symptom"

  local n; n="$(norm_of "$hyp")"
  # Already refuted, verbatim? Refuse — and say when and on what evidence.
  if [ -f "$LEDGER" ]; then
    local prior
    prior="$(grep "\"norm\":\"$n\"" "$LEDGER" 2>/dev/null | tail -1)"
    if [ -n "$prior" ]; then
      local pid; pid="$(fld "$prior" id)"
      if [ "$(status_of "$pid")" = "refute" ]; then
        echo "❌ hypothesis: that exact idea was REFUTED as $pid on $(fld "$prior" ts)." >&2
        echo "   observed: $(fld "$(grep "\"id\":\"$pid\"" "$LEDGER" | tail -1)" observed)" >&2
        echo "   Re-open it only with something that changed: hypothesis.sh reopen $pid --new-evidence \"<what is different now>\"" >&2
        exit 2
      fi
    fi
  fi

  # Strike escalation: has this SYMPTOM already survived N explanations?
  local strikes=0 escalated=false
  if [ -n "$symptom" ] && [ -f "$LEDGER" ]; then
    strikes="$(awk -v s="$symptom" 'index($0, "\"symptom\":\"" s "\"") && index($0, "\"event\":\"refute\"")' "$LEDGER" 2>/dev/null | pg_count)"
    if [ "${strikes:-0}" -ge "$STRIKES" ]; then escalated=true; fi
  fi

  local anch=""
  for a in $anchors; do
    local ap="${a%%:*}" al="${a##*:}"; [ "$al" = "$ap" ] && al=0
    anch="${anch:+$anch,}{\"path\":\"$(pg_json_escape "$ap")\",\"line\":${al:-0},\"blob\":\"$(pg_sha1 "$ap")\"}"
  done

  local id; id="h-$(printf '%s|%s|%s' "$hyp" "$(pg_now)" "$RANDOM" | pg_sha1 | cut -c1-8)"
  local body
  body="{\"id\":\"$id\",\"ts\":\"$(pg_now)\",\"event\":\"open\",\"kind\":\"$kind\",\"symptom\":\"$(pg_json_escape "$symptom")\""
  body="$body,\"escalated\":$escalated,\"strikes\":${strikes:-0}"
  body="$body,\"hypothesis\":\"$(pg_json_escape "$hyp")\",\"prediction\":\"$(pg_json_escape "$pred")\",\"cmd\":\"$(pg_json_escape "$cmd")\",\"norm\":\"$n\""
  body="$body,\"observed\":\"\",\"exit\":null,\"anchors\":[$anch],\"head_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"via\":\"hypothesis.sh\""
  pg_ledger_append "$LEDGER" "$body"

  echo "✅ $id open ($kind)${symptom:+ · symptom: $symptom}"
  [ -z "$pred" ] && echo "   ▫️  no --prediction: an idea with no falsifiable consequence cannot be killed, only defended. What MUST exist if this is true?"
  [ -z "$cmd" ] && [ -n "$pred" ] && echo "   ▫️  no --cmd: name the command that would reveal that mark, then run it."
  if [ "$escalated" = "true" ]; then
    echo "   ⚠️  ESCALATED: '$symptom' has already survived $strikes refuted explanation(s)."
    echo "       The bar inverts here (SKILL § external causes). This gate now REQUIRES an"
    echo "       adversarial pass, and 'effect observed, cause unknown' is a better record"
    echo "       than a third confident guess."
  fi
}

_close() { # _close <event> <id> <args...>
  local ev="$1" id="$2"; shift 2
  [ -n "$id" ] || die "$ev needs an id"
  local prior; prior="$(row_of "$id")"
  [ -n "$prior" ] || die "no hypothesis $id"
  local run="" observed="" newev=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run) shift; run="${1:-}" ;;
      --observed) shift; observed="${1:-}" ;;
      --new-evidence) shift; newev="${1:-}" ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done

  local exit_code="null" out_sha=""
  if [ -n "$run" ]; then
    local t; t="$(mktemp)"
    with_timeout bash -c "$run" >"$t" 2>&1; exit_code=$?
    out_sha="$(pg_sha1 < "$t")"
    [ -z "$observed" ] && observed="$(head -3 "$t" | tr '\n' ' ' | cut -c1-200)"
    # Silence IS the observation when the command is a `grep -q`-style probe: "the
    # mark is absent" is exactly what kills a hypothesis, and a blank `observed`
    # field would lose the only thing the run established.
    [ -z "$observed" ] && observed="\`$run\` exited $exit_code with no output$( [ "$exit_code" != 0 ] && printf ' — the predicted mark is ABSENT' )"
    rm -f "$t"
  fi

  # A verdict with nothing behind it is the thing this ledger exists to prevent —
  # especially `confirm`, which is where an invented culprit becomes the record.
  if [ "$ev" = "confirm" ] || [ "$ev" = "refute" ]; then
    [ -n "$run" ] || [ -n "$observed" ] || \
      die "$ev needs evidence: --run \"<the command that reveals the mark>\" or --observed \"<what you actually saw>\". Closing a hypothesis on a feeling is how an absent culprit becomes folklore."
  fi
  if [ "$ev" = "reopen" ]; then
    [ -n "$newev" ] || die "reopen needs --new-evidence: what changed since it was ruled out? Without that, re-opening is just the same guess arriving later."
  fi

  local body
  body="{\"id\":\"$id\",\"ts\":\"$(pg_now)\",\"event\":\"$ev\",\"kind\":\"$(fld "$prior" kind)\",\"symptom\":\"$(fld "$prior" symptom)\""
  body="$body,\"escalated\":false,\"strikes\":0"
  body="$body,\"hypothesis\":\"$(fld "$prior" hypothesis)\",\"prediction\":\"$(fld "$prior" prediction)\",\"cmd\":\"$(pg_json_escape "$run")\",\"norm\":\"$(fld "$prior" norm)\""
  body="$body,\"observed\":\"$(pg_json_escape "$observed")\",\"exit\":${exit_code},\"out_sha\":\"$out_sha\""
  body="$body,\"new_evidence\":\"$(pg_json_escape "$newev")\",\"anchors\":[],\"head_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"via\":\"hypothesis.sh\""
  pg_ledger_append "$LEDGER" "$body"
  echo "✅ $id $ev${run:+ (exit $exit_code)}"

  if [ "$ev" = "refute" ]; then
    local sym; sym="$(fld "$prior" symptom)"
    if [ -n "$sym" ]; then
      local n2; n2="$(awk -v s="$sym" 'index($0, "\"symptom\":\"" s "\"") && index($0, "\"event\":\"refute\"")' "$LEDGER" 2>/dev/null | pg_count)"
      if [ "${n2:-0}" -ge "$STRIKES" ]; then
        echo "   ⚠️  '$sym' has now survived $n2 explanations. STOP hammering: the SKILL's rule is"
        echo "       to change APPROACH, and from here the bar inverts — the next hypothesis on this"
        echo "       symptom is marked escalated and the gate will require an adversarial pass."
      fi
    fi
  fi
}

cmd_list() {
  local filter=""
  while [ $# -gt 0 ]; do case "$1" in --open) filter=open ;; --refuted) filter=refute ;; esac; shift; done
  [ -f "$LEDGER" ] || return 0
  local ids; ids="$(grep -o '"id":"h-[0-9a-f]*"' "$LEDGER" 2>/dev/null | sed -e 's/^"id":"//' -e 's/"$//' | awk '!seen[$0]++')"
  for id in $ids; do
    local st; st="$(status_of "$id")"
    case "$filter" in
      open)   is_open "$id" || continue ;;
      refute) [ "$st" = "refute" ] || continue ;;
    esac
    local first last
    first="$(row_of "$id")"; last="$(grep "\"id\":\"$id\"" "$LEDGER" | tail -1)"
    printf '%s  %-7s %-9s %s\n' "$id" "$st" "$(fld "$first" kind)" "$(fld "$first" hypothesis)"
    [ "$st" = "refute" ] && [ -n "$(fld "$last" observed)" ] && printf '            ruled out by: %s\n' "$(fld "$last" observed)"
  done
}

cmd_show() {
  local id="${1:-}"; [ -n "$id" ] || die "show needs an id"
  grep "\"id\":\"$id\"" "$LEDGER" 2>/dev/null || die "no hypothesis $id"
}

# What a fresh context needs to not repeat itself. Read by hooks/session-hook.sh.
cmd_brief() {
  [ -f "$LEDGER" ] || return 0
  local open_l refuted_l
  open_l="$(cmd_list --open)"; refuted_l="$(cmd_list --refuted)"
  [ -n "$open_l" ] && { echo "OPEN hypotheses (still live — do not restart the investigation):"; printf '%s\n' "$open_l" | sed 's/^/  /'; }
  [ -n "$refuted_l" ] && { echo "ALREADY REFUTED (do not re-propose without new evidence):"; printf '%s\n' "$refuted_l" | sed 's/^/  /'; }
  local esc; esc="$(grep '"escalated":true' "$LEDGER" 2>/dev/null | tail -1)"
  [ -n "$esc" ] && echo "ESCALATED symptom '$(fld "$esc" symptom)': the bar is inverted — an absent culprit is never disproven, so 'cause unknown' beats a third guess."
  return 0
}

cmd_gc() {
  local keep=50
  while [ $# -gt 0 ]; do case "$1" in --keep) shift; keep="${1:-50}" ;; esac; shift; done
  [ -f "$LEDGER" ] || return 0
  local tmp; tmp="$(mktemp)"; tail -"$keep" "$LEDGER" > "$tmp"
  : > "$LEDGER"
  while IFS= read -r r; do pg_ledger_append "$LEDGER" "$(printf '%s' "$r" | sed -e 's/,"prev":"[^"]*"}$//')"; done < "$tmp"
  rm -f "$tmp"; echo "✅ kept the last $keep event(s)"
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  refute) shift; _close refute "$@" ;;
  confirm) shift; _close confirm "$@" ;;
  reopen) shift; _close reopen "$@" ;;
  park) shift; _close park "${1:-}" --observed "parked" ;;
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  brief) shift; cmd_brief "$@" ;;
  gc) shift; cmd_gc "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (open|refute|confirm|reopen|park|list|show|brief|gc)" ;;
esac
