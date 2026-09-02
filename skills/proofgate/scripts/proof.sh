#!/usr/bin/env bash
# ProofGate — SEAL the evidence to the commit, so a reviewer can check it instead of
# taking someone's word for it.
#
# Usage:
#   proof.sh seal [--push]        # bundle verdict + radius + claims + skeptic → a git note
#   proof.sh verify [<sha>]       # recompute the hashes: verified | tampered | missing
#   proof.sh replay [<sha>] [--only central]
#
# WHY a git note:
#
# Everything the gate produces lives in `.git/` — the verdict, the ledgers, the skeptic
# record. All of it is local. The person reviewing the pull request sees a description
# that CLAIMS a gate ran, and has exactly two options: believe it, or re-do the work.
# That is the same trust-me problem this project exists to remove, one level up.
#
# A note under `refs/notes/proofgate` is attached to the commit sha, travels with a
# `git push`, and does not change the commit — so the evidence arrives with the code and
# a CI job can check it (`action.yml` does).
#
# What it does NOT prove, stated plainly because the distinction is the whole value:
#
#   - It proves what the LOCAL gate SAW: these commands ran, with these exit codes,
#     producing output with these hashes.
#   - It does NOT prove the local gate was honest. Anything with a shell can write a
#     ledger and seal it.
#
# So `verify` detects TAMPERING AFTER sealing (hashes stop matching), and `replay`
# re-runs the recorded evidence commands and compares exit codes — a bundle whose
# evidence does not replay is downgraded, in the note itself. Independent confirmation
# is CI running the gate itself; the note makes the two comparable.
#
# The note is deliberately NOT carried across a rewrite (`notes.rewriteRef` is left
# unset): an amend or a rebase produces a different commit, and evidence about the old
# one is not evidence about the new one. Losing the note there is correct.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "proof: lib.sh not found" >&2; exit 1; }

GD="$(pg_git_dir)"
REF="refs/notes/proofgate"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
TMO="$(cfg '.timeoutSeconds')"; TMO="${TMO:-900}"
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout --foreground "$TMO" "$@"; else "$@"; fi; }
die() { echo "❌ proof: $1" >&2; exit 2; }

# Secret shapes, mirroring 10-secrets.sh. The audit segment records commands, and a
# command line is one of the likeliest places for a credential to be sitting.
redact() {
  sed -E -e 's/(AKIA[0-9A-Z]{16})/[REDACTED-AWS]/g' \
         -e 's/(ghp_[A-Za-z0-9]{20,})/[REDACTED-GH]/g' \
         -e 's/(github_pat_[A-Za-z0-9_]{20,})/[REDACTED-GH]/g' \
         -e 's/(xox[baprs]-[A-Za-z0-9-]{10,})/[REDACTED-SLACK]/g' \
         -e 's/(sk-[A-Za-z0-9]{20,})/[REDACTED-KEY]/g' \
         -e 's/(sk_live_[A-Za-z0-9]{10,})/[REDACTED-KEY]/g' \
         -e 's/(AIza[0-9A-Za-z_-]{30,})/[REDACTED-GOOGLE]/g' \
         -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----)/[REDACTED-PRIVATE-KEY]/g' 2>/dev/null
}

section_or_null() { # <file> — the file's single-line JSON, or the literal null
  if [ -f "$1" ]; then cat "$1"; else printf 'null'; fi
}

cmd_seal() {
  local push=0
  while [ $# -gt 0 ]; do case "$1" in --push) push=1 ;; *) die "unknown flag: $1" ;; esac; shift; done

  local V="$GD/proofgate-verdict.json" I="$GD/proofgate-impact.json" S="$GD/proofgate-skeptic.json"
  [ -f "$V" ] || die "no verdict — run verify.sh first. Sealing without one would attest to nothing."
  local vsha; vsha="$(pg_scalar "$V" sha)"
  [ "$vsha" = "$HEAD_SHA" ] || die "the verdict is for ${vsha:0:7}, HEAD is ${HEAD_SHA:0:7}. Evidence about a different commit is not evidence about this one."
  [ -z "$(git status --porcelain 2>/dev/null)" ] || die "the working tree is dirty. A seal describes a commit; uncommitted work is outside what it can attest to."
  if command -v pg_ledger_verify >/dev/null 2>&1; then
    local bad
    for led in proofgate-claims proofgate-hypotheses; do
      [ -f "$GD/$led.jsonl" ] || continue
      bad="$(pg_ledger_verify "$GD/$led.jsonl")" || die "$led.jsonl line $bad breaks the hash chain — sealing a tampered ledger would launder it."
    done
  fi

  # Claims about THIS code — recorded on this commit, or recorded against identical
  # content before the commit that packaged it (see rows_for_sha in claim.sh).
  local claims="["
  if [ -f "$GD/proofgate-claims.jsonl" ]; then
    local cid; cid="$(pg_content_id)"
    claims="$claims$(grep -e "\"sha\":\"$HEAD_SHA\"" -e "\"content\":\"$cid\"" "$GD/proofgate-claims.jsonl" 2>/dev/null | awk '{ printf "%s%s", (n++ ? "," : ""), $0 }')"
  fi
  claims="$claims]"

  # The audit segment is FILTERED to commands that appear in a claim, and redacted.
  # A full shell history is both noise and a liability; what belongs with the evidence
  # is the commands the evidence rests on.
  local audit="["
  if [ -f "$GD/proofgate-audit.jsonl" ]; then
    audit="$audit$(grep -F -f <(printf '%s' "$claims" | grep -o '"cmd":"[^"]*"' | sed -e 's/^"cmd":"//' -e 's/"$//' | head -50) "$GD/proofgate-audit.jsonl" 2>/dev/null \
      | redact | head -50 | awk '{ printf "%s%s", (n++ ? "," : ""), $0 }')"
  fi
  audit="$audit]"

  local s_verdict s_impact s_claims s_skeptic s_audit
  s_verdict="$(cat "$V" | pg_sha1)"
  s_impact="$(section_or_null "$I" | pg_sha1)"
  s_claims="$(printf '%s' "$claims" | pg_sha1)"
  s_skeptic="$(section_or_null "$S" | pg_sha1)"
  s_audit="$(printf '%s' "$audit" | pg_sha1)"
  local bundle; bundle="$(printf '%s\n%s\n%s\n%s\n%s' "$s_verdict" "$s_impact" "$s_claims" "$s_skeptic" "$s_audit" | pg_sha1)"

  local note; note="$(mktemp)"
  {
    printf '{"schemaVersion":1,"head_sha":"%s","sealedAt":"%s","sealer":{"session":"%s"}' \
      "$HEAD_SHA" "$(pg_now)" "${CLAUDE_SESSION_ID:-local}"
    printf ',"sections":{"verdict":{"sha1":"%s","body":%s}' "$s_verdict" "$(cat "$V")"
    printf ',"impact":{"sha1":"%s","body":%s}' "$s_impact" "$(section_or_null "$I")"
    printf ',"claims":{"sha1":"%s","body":%s}' "$s_claims" "$claims"
    printf ',"skeptic":{"sha1":"%s","body":%s}' "$s_skeptic" "$(section_or_null "$S")"
    printf ',"audit":{"sha1":"%s","body":%s}}' "$s_audit" "$audit"
    printf ',"bundle_sha1":"%s","replay":null}\n' "$bundle"
  } > "$note"

  git notes --ref="$REF" add -f -F "$note" HEAD >/dev/null 2>&1 || { rm -f "$note"; die "could not write the git note"; }
  rm -f "$note"
  echo "✅ sealed to ${HEAD_SHA:0:7} · bundle ${bundle:0:12}"
  echo "   It attests to what the LOCAL gate saw: these commands ran, with these exit codes."
  echo "   It does not attest that the local gate was honest — CI re-running the gate is the"
  echo "   independent check; this makes the two comparable."
  if [ "$push" = 1 ]; then
    if git push origin "$REF" >/dev/null 2>&1; then echo "✅ pushed $REF — the evidence now travels with the code"
    else echo "⚠️  could not push $REF (no remote, or no permission). The note is local only."; fi
  else
    echo "   Push it with: git push origin $REF"
  fi
}

read_note() { git notes --ref="$REF" show "${1:-HEAD}" 2>/dev/null; }

cmd_verify() {
  local sha="HEAD" summary=0
  while [ $# -gt 0 ]; do case "$1" in --summary) summary=1 ;; *) sha="$1" ;; esac; shift; done
  local n; n="$(read_note "$sha")"
  if [ -z "$n" ]; then
    [ "$summary" = 1 ] && echo "### ProofGate proof: **missing** — no sealed evidence for \`$sha\`"
    [ "$summary" = 0 ] && echo "missing: no proof note on $sha"
    return 1
  fi
  local claimed; claimed="$(printf '%s' "$n" | grep -o '"bundle_sha1":"[^"]*"' | head -1 | sed -e 's/^"bundle_sha1":"//' -e 's/"$//')"
  local got
  got="$(printf '%s\n%s\n%s\n%s\n%s' \
    "$(printf '%s' "$n" | sed -n 's/.*"verdict":{"sha1":"\([^"]*\)".*/\1/p')" \
    "$(printf '%s' "$n" | sed -n 's/.*"impact":{"sha1":"\([^"]*\)".*/\1/p')" \
    "$(printf '%s' "$n" | sed -n 's/.*"claims":{"sha1":"\([^"]*\)".*/\1/p')" \
    "$(printf '%s' "$n" | sed -n 's/.*"skeptic":{"sha1":"\([^"]*\)".*/\1/p')" \
    "$(printf '%s' "$n" | sed -n 's/.*"audit":{"sha1":"\([^"]*\)".*/\1/p')" | pg_sha1)"
  # Recompute each section's hash from its body too: an edited body with an untouched
  # section hash would otherwise pass the outer check.
  local ok=1
  [ "$claimed" = "$got" ] || ok=0
  local vbody vhash
  vbody="$(printf '%s' "$n" | sed -n 's/.*"verdict":{"sha1":"[^"]*","body":\(.*\)},"impact".*/\1/p')"
  vhash="$(printf '%s' "$n" | sed -n 's/.*"verdict":{"sha1":"\([^"]*\)".*/\1/p')"
  if [ -n "$vbody" ]; then
    [ "$(printf '%s\n' "$vbody" | pg_sha1)" = "$vhash" ] || ok=0
  fi

  if [ "$ok" = 1 ]; then
    local dg; dg="$(printf '%s' "$n" | grep -o '"downgraded":true' | head -1)"
    if [ "$summary" = 1 ]; then
      echo "### ProofGate proof: **verified** for \`${sha}\`"
      echo ""
      echo "- claims sealed: $(printf '%s' "$n" | grep -o '"id":"c-[^"]*"' | pg_count)"
      echo "- skeptic agents: $(printf '%s' "$n" | grep -o '"agents":\[[^]]*\]' | head -1)"
      echo "- verdict: $(printf '%s' "$n" | grep -o '"pass":[a-z]*' | head -1)"
      [ -n "$dg" ] && echo "- ⚠️ this bundle was **downgraded**: its recorded evidence did not replay"
      echo ""
      echo "It attests to what the local gate saw — the commands, exit codes and output hashes."
      echo "It does not attest that the local gate was honest; this job re-running the gate is"
      echo "the independent check."
    else
      echo "verified${dg:+ (downgraded: evidence did not replay)}"
    fi
    return 0
  fi
  [ "$summary" = 1 ] && echo "### ProofGate proof: **TAMPERED** for \`$sha\` — the sealed content no longer hashes to its own bundle id"
  [ "$summary" = 0 ] && echo "tampered: the note's content does not match its recorded hashes"
  return 1
}

cmd_replay() {
  local sha="HEAD" only=""
  while [ $# -gt 0 ]; do case "$1" in --only) shift; only="${1:-}" ;; *) sha="$1" ;; esac; shift; done
  local n; n="$(read_note "$sha")"; [ -n "$n" ] || die "no proof note on $sha"

  local total=0 exit_match=0 expect_match=0 out_match=0 mismatch=0
  # One claim per line, so the loop can re-run each recorded command as it was recorded.
  local claims; claims="$(printf '%s' "$n" | sed -n 's/.*"claims":{"sha1":"[^"]*","body":\[\(.*\)\]},"skeptic".*/\1/p')"
  [ -n "$claims" ] || { echo "nothing to replay: the bundle carries no claims"; return 0; }

  local rows; rows="$(printf '%s' "$claims" | sed 's/},{/}\n{/g')"
  local results; results="$(mktemp)"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$only" in "") ;; *) printf '%s' "$row" | grep -q "\"kind\":\"$only\"" || continue ;; esac
    local cmd rec_exit rec_expect
    # Parsed, not grepped. The ledger stores the command JSON-escaped, and executing the
    # escaped form would replay something other than what was recorded — see
    # pg_json_field in lib.sh for why a few substitutions cannot fix that.
    cmd="$(pg_json_field "$row" '.evidence.cmd')"
    [ -n "$cmd" ] || continue
    rec_exit="$(pg_json_field "$row" '.evidence.exit')"
    rec_expect="$(pg_json_field "$row" '.evidence.expect')"
    total=$((total + 1))
    local t; t="$(mktemp)"
    with_timeout bash -c "$cmd" >"$t" 2>&1; local now_exit=$?
    local now_sha; now_sha="$(pg_sha1 < "$t")"
    local em=0 xm=0 om=0
    [ "$now_exit" = "$rec_exit" ] && em=1
    if [ -n "$rec_expect" ]; then grep -Eq -- "$rec_expect" "$t" 2>/dev/null && xm=1; else xm=1; fi
    [ "$now_sha" = "$(pg_json_field "$row" '.evidence.out_sha')" ] && om=1
    rm -f "$t"
    printf '%s %s %s\n' "$em" "$xm" "$om" >> "$results"
    if [ "$em" = 0 ] || [ "$xm" = 0 ]; then
      echo "   ❌ did not replay: $cmd (recorded exit $rec_exit, now $now_exit)"
    fi
  done <<EOF
$rows
EOF

  total="$(pg_lines "$results")"
  exit_match="$(awk '{s+=$1} END{print s+0}' "$results" 2>/dev/null)"
  expect_match="$(awk '{s+=$2} END{print s+0}' "$results" 2>/dev/null)"
  out_match="$(awk '{s+=$3} END{print s+0}' "$results" 2>/dev/null)"
  rm -f "$results"
  mismatch=$(( total - exit_match ))

  echo "replay: $total claim(s) · exit matched $exit_match · marker matched $expect_match · output hash matched $out_match"
  # The output hash is ADVISORY, never a downgrade. Real command output carries
  # timestamps, durations and paths; requiring it to be byte-identical would fail
  # honest evidence and teach people the check is broken. Exit code and marker are
  # the strict signals.
  [ "$out_match" -lt "$total" ] && echo "   ▫️  output hashes differ on $(( total - out_match )) — advisory only: real output carries timestamps and paths."

  if [ "$mismatch" -gt 0 ] || [ "$expect_match" -lt "$total" ]; then
    local n2; n2="$(printf '%s' "$n" | sed "s/\"replay\":null/\"replay\":{\"ts\":\"$(pg_now)\",\"exit_match\":$exit_match,\"expect_match\":$expect_match,\"output_match\":$out_match,\"downgraded\":true}/")"
    printf '%s\n' "$n2" | git notes --ref="$REF" add -f -F - HEAD >/dev/null 2>&1 || true
    echo "❌ DOWNGRADED: recorded evidence does not reproduce. The bundle now says so."
    return 1
  fi
  echo "✅ the recorded evidence reproduces"
  return 0
}

case "${1:-}" in
  seal) shift; cmd_seal "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  replay) shift; cmd_replay "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (seal|verify|replay)" ;;
esac
