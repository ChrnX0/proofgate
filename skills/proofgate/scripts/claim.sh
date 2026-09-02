#!/usr/bin/env bash
# ProofGate — the CLAIMS LEDGER. Evidence as a record, not as prose.
#
# Usage:
#   claim.sh add --claim "<text>" --level E0..E4 [--kind <kind>] [--hypothesis h-x]
#                [--same-as c-x] (--run "<cmd>" [--expect <ERE>] | --artifact <path>)
#   claim.sh list [--sha <sha>] [--json]
#   claim.sh render [--sha <sha>]        # the status block, GENERATED from the ledger
#   claim.sh show <id>
#   claim.sh gc [--keep <n>]             # drop rows older than the last n SHAs
#
# WHY a ledger, when the skill already asks for evidence in writing:
#
# Because "in writing" is the loophole. The judgment gate says a runtime claim is done
# only at E3, and an agent that has run nothing can still type `VERIFIED (E3): the
# checkout flow works`. Every word of that is free. The whole apparatus — the evidence
# hierarchy, the banned-language list, the excuse-buster table — rests on the author
# volunteering an honest level, which is precisely the thing under pressure at the
# moment of writing a status.
#
# So the level stops being something you TYPE and becomes something you EARN:
#
#   - `add --run` EXECUTES the command itself and records the exit code, a hash of the
#     output, and the duration. The claim's level is bounded by what actually happened,
#     not by what was asserted. There is no code path where a level above E0 is written
#     without this script having run something.
#   - E3/E4 additionally require `--expect`: a marker that must appear in the output.
#     "The endpoint returned 200" is compatible with the OLD build still being live —
#     the SKILL has always said to assert a marker unique to the NEW version, and this
#     makes it mechanical instead of remembered.
#   - `render` GENERATES the status block from the rows. A status typed by hand is, by
#     definition, E0: nothing produced it. That is the loophole closed.
#
# What this does NOT do, stated plainly: it cannot tell whether `--expect ok` against
# /health is a meaningful assertion. Semantics are the skeptic's job (step 3). What it
# removes is the ability to claim a level with nothing behind it at all.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "claim: lib.sh not found" >&2; exit 1; }

GD="$(pg_git_dir)"
LEDGER="$GD/proofgate-claims.jsonl"
OUTDIR="$GD/proofgate-claims"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
TMO="$(cfg '.timeoutSeconds')"; TMO="${TMO:-900}"
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout --foreground "$TMO" "$@"; else "$@"; fi; }

MODE="normal"
[ -f "$GD/proofgate-mode" ] && grep -q '"mode":"prototype"' "$GD/proofgate-mode" 2>/dev/null && MODE="prototype"

die() { echo "❌ claim: $1" >&2; exit 2; }

level_num() { case "$1" in E0) echo 0 ;; E1) echo 1 ;; E2) echo 2 ;; E3) echo 3 ;; E4) echo 4 ;; *) echo -1 ;; esac; }

# A command that cannot fail is not evidence. Two shapes qualify, and the difference
# between them matters:
#
#   1. a SIMPLE command whose exit status is constant (`true`, a bare `echo`, `pwd`);
#   2. any command ending in a success-forcing suffix (`|| true`, `; exit 0`, `2>/dev/null || :`)
#      — the classic way a red run is laundered into a green one.
#
# Prefix matching alone would be wrong: `echo hi | grep hi` starts with `echo` and can
# absolutely fail, and refusing it would push people toward worse evidence, not better.
is_noop() {
  local c; c="$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # (2) exit status forced to success, whatever ran before it
  printf '%s' "$c" | grep -Eq '(\|\|[[:space:]]*(true|:)|;[[:space:]]*(exit[[:space:]]+0|true|:))[[:space:]]*$' && return 0
  # (1) a single simple command with no pipeline or list operators
  printf '%s' "$c" | grep -Eq '[|&;]' && return 1
  case "$c" in
    true|:|"/bin/true"|pwd|date|ls|"cat /dev/null") return 0 ;;
    echo|echo\ *|printf|printf\ *) return 0 ;;
  esac
  return 1
}

cmd_add() {
  local claim="" level="" kind="central" hyp="" same="" run="" expect="" artifact=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --claim) shift; claim="${1:-}" ;;
      --level) shift; level="${1:-}" ;;
      --kind) shift; kind="${1:-}" ;;
      --hypothesis) shift; hyp="${1:-}" ;;
      --same-as) shift; same="${1:-}" ;;
      --run) shift; run="${1:-}" ;;
      --expect) shift; expect="${1:-}" ;;
      --artifact) shift; artifact="${1:-}" ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done

  case "$kind" in central|supporting|red-test|green-test|gap) ;; *) die "unknown --kind '$kind'" ;; esac
  if [ -z "$claim" ]; then
    case "$kind" in
      red-test)   claim="the bug reproduces: this command is RED before the fix" ;;
      green-test) claim="the same command that was red now passes" ;;
      gap)        claim="declared gap (no evidence)" ;;
      *)          claim="$kind claim" ;;
    esac
  fi
  # Test-pair kinds carry their own level semantics: a red test is E2 evidence that the
  # bug is real, a green test E2 that it is gone. Asking the caller to also type a level
  # invites a mismatch between the two.
  case "$kind" in red-test|green-test) [ -n "$level" ] || level="E2" ;; gap) [ -n "$level" ] || level="E0" ;; esac
  [ -n "$level" ] || die "--level is required (E0..E4)"
  [ "$(level_num "$level")" -ge 0 ] || die "--level must be one of E0 E1 E2 E3 E4"

  local ln; ln="$(level_num "$level")"
  if [ "$ln" -ge 1 ] && [ -z "$run" ] && [ -z "$artifact" ]; then
    die "$level needs evidence: pass --run \"<command>\" (it will be EXECUTED and its exit code recorded) or --artifact <file>. Without one of those the honest level is E0."
  fi
  if [ "$ln" -ge 3 ] && [ -z "$expect" ]; then
    die "$level needs --expect <regex>: a marker that must appear in the output and is UNIQUE TO THE NEW VERSION. A 200, or a string the old build also prints, is compatible with nothing having been deployed."
  fi
  if [ -n "$run" ] && is_noop "$run"; then
    die "'$run' cannot fail, so it proves nothing. Run the command that would go red if the claim were false."
  fi
  if [ "$kind" = "green-test" ] && [ -z "$same" ]; then
    die "--kind green-test needs --same-as <red-claim-id>: proving a fix means the SAME command that failed now passes. A different command passing proves a different thing."
  fi

  local exit_code="null" out_sha="" out_path="" dur=0 expect_matched="null" art_sha="" started ended
  if [ -n "$run" ]; then
    mkdir -p "$OUTDIR" 2>/dev/null
    local tmpout; tmpout="$(mktemp)"
    started="$(pg_epoch)"
    with_timeout bash -c "$run" >"$tmpout" 2>&1; exit_code=$?
    ended="$(pg_epoch)"
    dur=$(( (ended - started) * 1000 ))
    out_sha="$(pg_sha1 < "$tmpout")"
    if [ -n "$expect" ]; then
      if grep -Eq -- "$expect" "$tmpout" 2>/dev/null; then expect_matched=true; else expect_matched=false; fi
    fi
  fi
  if [ -n "$artifact" ]; then
    [ -f "$artifact" ] || die "--artifact '$artifact' does not exist"
    art_sha="$(pg_sha1 "$artifact")"
  fi

  # Red/green pairing is checked against what HAPPENED, not what was intended.
  if [ "$kind" = "red-test" ] && [ "$exit_code" = "0" ]; then
    rm -f "${tmpout:-}"
    die "a red test must be RED: '$run' exited 0. A test that passes before the fix cannot show the bug — it is testing something else."
  fi
  if [ "$kind" = "green-test" ]; then
    local red_cmd
    red_cmd="$(grep "\"id\":\"$same\"" "$LEDGER" 2>/dev/null | tail -1 | grep -o '"cmd":"[^"]*"' | head -1 | sed -e 's/^"cmd":"//' -e 's/"$//')"
    [ -n "$red_cmd" ] || { rm -f "${tmpout:-}"; die "--same-as '$same' is not in the ledger"; }
    local run_esc; run_esc="$(pg_json_escape "$run")"
    [ "$red_cmd" = "$run_esc" ] || { rm -f "${tmpout:-}"; die "green-test must re-run the SAME command as $same. Recorded there: [$red_cmd]"; }
    [ "$exit_code" = "0" ] || { rm -f "${tmpout:-}"; die "'$run' still exits $exit_code — that is not green yet."; }
  fi

  # The RECORDED level is what the run supports, which is not always what was claimed.
  local recorded="$level" reason="null"
  if [ -n "$run" ] && [ "$exit_code" != "0" ] && [ "$kind" != "red-test" ]; then
    recorded="E0"; reason='"command-failed"'
  elif [ "$expect_matched" = "false" ]; then
    recorded="E0"; reason='"expect-unmatched"'
  elif [ "$MODE" = "prototype" ] && [ "$(level_num "$level")" -gt 1 ]; then
    # Prototype mode relaxes the guards; it must not launder a level past them.
    recorded="E1"; reason='"prototype-mode"'
  fi

  local id; id="c-$(printf '%s|%s|%s' "$claim" "$(pg_now)" "$RANDOM" | pg_sha1 | cut -c1-8)"
  [ -n "$run" ] && { out_path="$OUTDIR/$id.out"; head -50 "${tmpout:-/dev/null}" > "$out_path" 2>/dev/null; rm -f "${tmpout:-}"; }

  local body
  body="{\"id\":\"$id\",\"ts\":\"$(pg_now)\",\"sha\":\"$HEAD_SHA\",\"content\":\"$(pg_content_id)\",\"mode\":\"$MODE\""
  body="$body,\"kind\":\"$kind\",\"hypothesis\":$([ -n "$hyp" ] && printf '"%s"' "$hyp" || echo null)"
  body="$body,\"same_as\":$([ -n "$same" ] && printf '"%s"' "$same" || echo null)"
  body="$body,\"claim\":\"$(pg_json_escape "$claim")\",\"level_claimed\":\"$level\",\"level_recorded\":\"$recorded\",\"reason\":$reason"
  body="$body,\"evidence\":{\"cmd\":\"$(pg_json_escape "$run")\",\"exit\":${exit_code:-null},\"out_sha\":\"$out_sha\",\"out_path\":\"$out_path\""
  body="$body,\"expect\":$([ -n "$expect" ] && printf '"%s"' "$(pg_json_escape "$expect")" || echo null),\"expect_matched\":$expect_matched"
  body="$body,\"artifact\":$([ -n "$artifact" ] && printf '"%s"' "$(pg_json_escape "$artifact")" || echo null),\"artifact_sha\":\"$art_sha\",\"duration_ms\":$dur}"
  body="$body,\"via\":\"claim.sh\""
  pg_ledger_append "$LEDGER" "$body"

  if [ "$recorded" != "$level" ]; then
    echo "⚠️  $id recorded at $recorded, not $level ($(printf '%s' "$reason" | tr -d '"')) — the run does not support the claimed level."
  else
    echo "✅ $id recorded at $recorded${run:+ (exit ${exit_code}${expect:+, expect matched})}"
  fi
}

# Rows that describe THIS code. Two ways a row qualifies, and the second one matters:
#
#   - it was recorded on this commit (sha match), or
#   - it was recorded against identical CODE (content match) — which is what happens in
#     the natural order of work: prove it, then commit it. Keying on the sha alone
#     orphaned every claim made before the commit that packaged it, so a delivery with a
#     full ledger rendered as VERIFIED: NOTHING.
#
# It still does not survive a real change: `content` is a hash of every tracked blob plus
# untracked file, so editing anything invalidates the evidence — which is the property
# the SKILL calls "green WHEN?", and the one worth keeping.
rows_for_sha() {
  local sha="${1:-$HEAD_SHA}" cid
  [ -f "$LEDGER" ] || return 0
  if [ "$sha" = "$HEAD_SHA" ]; then
    cid="$(pg_content_id)"
    grep -e "\"sha\":\"$sha\"" -e "\"content\":\"$cid\"" "$LEDGER" 2>/dev/null
  else
    grep "\"sha\":\"$sha\"" "$LEDGER" 2>/dev/null
  fi
}
field() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed -e "s/^\"$2\":\"//" -e 's/"$//'; }

cmd_list() {
  local sha="$HEAD_SHA" asjson=0
  while [ $# -gt 0 ]; do case "$1" in --sha) shift; sha="${1:-$HEAD_SHA}" ;; --json) asjson=1 ;; esac; shift; done
  [ -f "$LEDGER" ] || { [ "$asjson" = 1 ] && echo "[]"; return 0; }
  if [ "$asjson" = 1 ]; then
    printf '['; rows_for_sha "$sha" | awk '{ printf "%s%s", (n++ ? "," : ""), $0 }'; printf ']\n'
    return 0
  fi
  rows_for_sha "$sha" | while IFS= read -r r; do
    printf '%s  %-11s %-3s  %s\n' "$(field "$r" id)" "$(field "$r" kind)" "$(field "$r" level_recorded)" "$(field "$r" claim)"
  done
}

# The highest level actually EARNED by a central claim on this commit. verify.sh reads
# this to compare against the level the blast radius demands.
cmd_achieved() {
  local sha="${1:-$HEAD_SHA}" best=0 lvl n
  [ -f "$LEDGER" ] || { echo "E0"; return 0; }
  while IFS= read -r r; do
    case "$r" in *'"kind":"central"'*) ;; *) continue ;; esac
    lvl="$(field "$r" level_recorded)"; n="$(level_num "$lvl")"
    [ "$n" -gt "$best" ] && best="$n"
  done <<EOF
$(rows_for_sha "$sha")
EOF
  echo "E$best"
}

# The status block is GENERATED. A status written by hand has no evidence behind it by
# construction — that is the entire point of this command existing.
cmd_render() {
  local sha="$HEAD_SHA"
  while [ $# -gt 0 ]; do case "$1" in --sha) shift; sha="${1:-$HEAD_SHA}" ;; esac; shift; done
  local rows; rows="$(rows_for_sha "$sha")"
  local V="$GD/proofgate-verdict.json" I="$GD/proofgate-impact.json"

  [ "$MODE" = "prototype" ] && echo "⚠️  UNVERIFIED PROTOTYPE — prototype mode is ON; nothing below is gated evidence."
  echo "PROOFGATE — $(git log -1 --format=%s 2>/dev/null | head -c 72)"

  if [ -f "$V" ]; then
    local fails warns
    fails="$(pg_scalar "$V" fails)"; warns="$(pg_scalar "$V" warns)"
    echo "Mechanical: $( [ "${fails:-0}" = 0 ] && echo '✅ passed' || echo "❌ ${fails} failing" ) · ${warns:-0} warning(s) · verdict for ${sha:0:7}"
  else
    echo "Mechanical: NOT RUN — run verify.sh (a status with no verdict is a guess)"
  fi
  if [ -f "$I" ]; then
    echo "Blast radius: $(pg_scalar "$I" risk_class) · needs $(pg_scalar "$I" required_level) · reachable here: $(pg_scalar "$I" max_achievable_level) · nav $(pg_scalar "$I" navigation_backend) ($(pg_scalar "$I" navigation_confidence))"
  fi

  if [ -z "$rows" ]; then
    echo "VERIFIED: NOTHING. No claims recorded for ${sha:0:7} — this delivery has no evidence."
    echo "          Record one: claim.sh add --claim \"...\" --level E3 --run \"<cmd>\" --expect \"<marker>\""
    return 0
  fi

  echo "VERIFIED (level · evidence):"
  printf '%s\n' "$rows" | while IFS= read -r r; do
    case "$r" in *'"kind":"gap"'*) continue ;; esac
    local lvl cmdtxt ex code
    lvl="$(field "$r" level_recorded)"
    cmdtxt="$(printf '%s' "$r" | grep -o '"cmd":"[^"]*"' | head -1 | sed -e 's/^"cmd":"//' -e 's/"$//')"
    ex="$(printf '%s' "$r" | grep -o '"expect":"[^"]*"' | head -1 | sed -e 's/^"expect":"//' -e 's/"$//')"
    code="$(printf '%s' "$r" | grep -o '"exit":[0-9-]*' | head -1 | sed 's/^"exit"://')"
    printf '  %s [%s] %s\n' "$lvl" "$(field "$r" kind)" "$(field "$r" claim)"
    [ -n "$cmdtxt" ] && printf '       ↳ %s → exit %s%s\n' "$cmdtxt" "${code:-?}" "${ex:+ · matched /$ex/}"
  done

  local gaps; gaps="$(printf '%s\n' "$rows" | grep '"kind":"gap"' || true)"
  if [ -n "$gaps" ]; then
    echo "NOT TESTED (declared):"
    printf '%s\n' "$gaps" | while IFS= read -r r; do printf '  · %s\n' "$(field "$r" claim)"; done
  fi

  local ach req; ach="$(cmd_achieved "$sha")"
  req="$( [ -f "$I" ] && pg_scalar "$I" required_level || echo "" )"
  if [ -n "$req" ] && [ "$(level_num "$ach")" -lt "$(level_num "$req")" ]; then
    echo "STATUS: NOT DONE — central claim is at $ach, this change requires $req."
  else
    echo "STATUS: central claim at $ach${req:+ (required $req)}"
  fi
}

cmd_show() {
  local id="${1:-}"; [ -n "$id" ] || die "show needs an id"
  grep "\"id\":\"$id\"" "$LEDGER" 2>/dev/null || die "no claim $id"
  local p="$OUTDIR/$id.out"; [ -f "$p" ] && { echo "--- recorded output ---"; cat "$p"; }
}

cmd_gc() {
  local keep=20
  while [ $# -gt 0 ]; do case "$1" in --keep) shift; keep="${1:-20}" ;; esac; shift; done
  [ -f "$LEDGER" ] || return 0
  local shas tmp; shas="$(git log --format=%H -"$keep" 2>/dev/null)"
  tmp="$(mktemp)"
  while IFS= read -r r; do
    printf '%s\n' "$shas" | grep -q "$(printf '%s' "$r" | grep -o '"sha":"[^"]*"' | head -1 | sed -e 's/^"sha":"//' -e 's/"$//')" && printf '%s\n' "$r"
  done < "$LEDGER" > "$tmp"
  # The chain is rebuilt, not carried: dropped rows would break every `prev` after them.
  : > "$LEDGER"
  while IFS= read -r r; do
    pg_ledger_append "$LEDGER" "$(printf '%s' "$r" | sed -e 's/,"prev":"[^"]*"}$//')"
  done < "$tmp"
  rm -f "$tmp"
  echo "✅ ledger kept rows for the last $keep commit(s)"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  list) shift; cmd_list "$@" ;;
  render) shift; cmd_render "$@" ;;
  achieved) shift; cmd_achieved "$@" ;;
  show) shift; cmd_show "$@" ;;
  gc) shift; cmd_gc "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (add|list|render|achieved|show|gc)" ;;
esac
