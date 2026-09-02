#!/usr/bin/env bash
# ProofGate — the SKEPTIC RECORDER. Refutations held to the standard they impose.
#
# Usage:
#   skeptic.sh record --agent <name> < findings.txt
#   skeptic.sh status      # present | stale | missing, for HEAD
#   skeptic.sh show
#
# Findings arrive one per line, from the panel's agents:
#   <VERDICT> <claim-id|-> :: <evidence> :: repro: <command|->
#
# WHY this is a script and not just the agent's prose:
#
# The adversarial pass had exactly the weakness it was built to attack. A skeptic that
# writes "REFUTED: this probably breaks under concurrency" has produced an E0 claim —
# words, no run — and because it *sounds* rigorous, it is trusted more than the E0 claim
# it just refuted. Skepticism with no evidence behind it is not the opposite of
# overclaiming; it is the same failure wearing the other costume, and it is more
# expensive, because it sends people to fix things that were never broken.
#
# So the rule is symmetric. Every REFUTED must carry a command that reproduces the
# problem, and this script RE-RUNS it:
#
#   - reproduces (the command actually fails)  → the refutation stands;
#   - does not reproduce, or no command given  → downgraded to UNPROVEN, with the
#     original verdict kept in the record, because "we could not show it" is honest and
#     "it is broken" was not established.
#
# And a skeptic cannot raise evidence either: a CONFIRMED is capped at the level the
# claims ledger actually recorded. An agent saying "yes, that is E3" does not make a run
# have happened.
#
# What survives as REFUTED opens a lesson — the finding stays visible until a guard or a
# test answers it, rather than living in one session's scrollback.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "skeptic: lib.sh not found" >&2; exit 1; }

GD="$(pg_git_dir)"
OUT="$GD/proofgate-skeptic.json"
CLAIMS="$GD/proofgate-claims.jsonl"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
TMO="$(cfg '.timeoutSeconds')"; TMO="${TMO:-900}"
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout --foreground "$TMO" "$@"; else "$@"; fi; }

die() { echo "❌ skeptic: $1" >&2; exit 2; }
lvl_n() { case "$1" in E0) echo 0 ;; E1) echo 1 ;; E2) echo 2 ;; E3) echo 3 ;; E4) echo 4 ;; *) echo 0 ;; esac; }

claim_level() { # the level the LEDGER recorded for a claim — the ceiling for CONFIRMED
  local id="$1"
  [ -f "$CLAIMS" ] || { echo "E0"; return; }
  grep "\"id\":\"$id\"" "$CLAIMS" 2>/dev/null | tail -1 \
    | grep -o '"level_recorded":"[^"]*"' | head -1 | sed -e 's/^"level_recorded":"//' -e 's/"$//' \
    | grep -E '^E[0-4]$' || echo "E0"
}

cmd_record() {
  local agent=""
  while [ $# -gt 0 ]; do case "$1" in --agent) shift; agent="${1:-}" ;; *) die "unknown flag: $1" ;; esac; shift; done
  [ -n "$agent" ] || die "--agent <name> is required"

  local findings="" n=0 downgraded=0 capped=0 kept=0 lessons=""
  while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    printf '%s' "$line" | grep -Eq '^(CONFIRMED|REFUTED|UNPROVEN)[[:space:]]' || continue
    n=$((n + 1))

    local verdict claim_id evidence repro
    verdict="$(printf '%s' "$line" | awk '{print $1}')"
    claim_id="$(printf '%s' "$line" | awk '{print $2}')"
    evidence="$(printf '%s' "$line" | sed -e 's/^[^:]*:: *//' -e 's/ *:: *repro:.*$//')"
    repro="$(printf '%s' "$line" | sed -n 's/.*:: *repro: *//p')"
    [ "$repro" = "-" ] && repro=""
    [ "$claim_id" = "-" ] && claim_id=""

    local original="$verdict" reproduced=null rexit=null rsha="" cap=""
    if [ "$verdict" = "REFUTED" ]; then
      if [ -z "$repro" ]; then
        # No command. The same standard the skeptic just applied to the author.
        verdict="UNPROVEN"; downgraded=$((downgraded + 1))
        evidence="$evidence [downgraded: no reproducing command was given, so this is an assertion, not a refutation]"
      else
        local t; t="$(mktemp)"
        with_timeout bash -c "$repro" >"$t" 2>&1; rexit=$?
        rsha="$(pg_sha1 < "$t")"; rm -f "$t"
        if [ "$rexit" = 0 ]; then
          # The command a skeptic says demonstrates the break, passing, demonstrates
          # nothing. Keeping the REFUTED here is how a rigorous-sounding sentence sends
          # people to fix code that was never broken.
          verdict="UNPROVEN"; reproduced=false; downgraded=$((downgraded + 1))
          evidence="$evidence [downgraded: \`$repro\` exited 0 — the failure did not reproduce]"
        else
          reproduced=true; kept=$((kept + 1))
        fi
      fi
    fi

    if [ "$verdict" = "CONFIRMED" ] && [ -n "$claim_id" ]; then
      cap="$(claim_level "$claim_id")"
      # A skeptic can lower confidence, never raise it. Agreement is not a run.
      capped=$((capped + 1))
    fi

    findings="${findings:+$findings,}{\"agent\":\"$(pg_json_escape "$agent")\",\"claim_id\":$([ -n "$claim_id" ] && printf '"%s"' "$claim_id" || echo null)"
    findings="$findings,\"verdict\":\"$verdict\",\"original_verdict\":\"$original\",\"level_cap\":\"${cap:-}\""
    findings="$findings,\"evidence\":\"$(pg_json_escape "$evidence")\""
    findings="$findings,\"repro\":{\"cmd\":\"$(pg_json_escape "$repro")\",\"exit\":$rexit,\"out_sha\":\"$rsha\",\"reproduced\":$reproduced}}"

    if [ "$verdict" = "REFUTED" ]; then
      local lid; lid="$(pg_lesson_add skeptic-refuted "$agent" "$evidence")"
      lessons="${lessons:+$lessons,}\"$lid\""
    fi
  done

  # Merge with findings already recorded for THIS head by OTHER agents; a stale file
  # from an older commit is replaced rather than appended to.
  local prior=""
  if [ -f "$OUT" ] && grep -q "\"head_sha\":\"$HEAD_SHA\"" "$OUT" 2>/dev/null; then
    prior="$(sed -n 's/.*"findings":\[\(.*\)\],"bottom_line".*/\1/p' "$OUT" 2>/dev/null)"
    [ -n "$prior" ] && findings="${prior}${findings:+,$findings}"
  fi
  local agents="$agent"
  if [ -n "$prior" ]; then
    agents="$(printf '%s' "$findings" | grep -o '"agent":"[^"]*"' | sed -e 's/^"agent":"//' -e 's/"$//' | LC_ALL=C sort -u | tr '\n' ' ')"
  fi
  local agents_json=""
  for a in $agents; do agents_json="${agents_json:+$agents_json,}\"$a\""; done

  local body
  body="{\"schemaVersion\":1,\"head_sha\":\"$HEAD_SHA\",\"ts\":\"$(pg_now)\",\"agents\":[$agents_json]"
  body="$body,\"findings\":[$findings],\"bottom_line\":\"$n finding(s) from $agent: $kept refutation(s) reproduced, $downgraded downgraded\",\"lessons\":[$lessons]}"
  local tmpv; tmpv="$(mktemp "$GD/.proofgate-skeptic.XXXXXX" 2>/dev/null || mktemp)"
  printf '%s\n' "$body" > "$tmpv" && mv "$tmpv" "$OUT"

  echo "✅ skeptic($agent): $n finding(s) recorded for ${HEAD_SHA:0:7}"
  [ "$kept" -gt 0 ] && echo "   ❌ $kept refutation(s) REPRODUCED — these are real and now open as lessons"
  [ "$downgraded" -gt 0 ] && echo "   ▫️  $downgraded downgraded to UNPROVEN (no repro command, or it did not fail)"
  [ "$capped" -gt 0 ] && echo "   ▫️  $capped confirmation(s) capped at the level the ledger recorded — agreement is not a run"
  return 0
}

cmd_status() {
  [ -f "$OUT" ] || { echo "missing"; return 0; }
  grep -q "\"head_sha\":\"$HEAD_SHA\"" "$OUT" 2>/dev/null && echo "present" || echo "stale"
}

cmd_show() { [ -f "$OUT" ] && cat "$OUT" || echo "no skeptic record"; }

case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  status) cmd_status ;;
  show) cmd_show ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (record|status|show)" ;;
esac
