#!/usr/bin/env bash
# ProofGate — PROJECT MEMORY, anchored to code instead of to prose.
#
# Usage:
#   memory.sh add --fact "<what is true>" --class decision|inference|incident
#                 [--provenance human|agent] [--anchor path[:line]]... [--ttl-diffs N]
#                 [--guard <name>] [--resolves L-x]
#   memory.sh recall [<path> | --changed] [--include-stale]
#   memory.sh revoke <id> --reason "<why>"        # a decision that no longer holds
#   memory.sh list [--stale] · show <id> · gc
#
# Lives in .proofgate/memory.jsonl — COMMITTED, so it is the team's memory, reviewable
# in a diff, and not one machine's private cache.
#
# WHY anchors, and why staleness is derived rather than stored:
#
# The obvious version of this feature is a notes file, and the obvious version is worse
# than nothing. A note that was true in March is indistinguishable from one that is true
# now, and the reader — usually a model with no way to check — treats both as fact. The
# failure mode is not forgetting; it is remembering something that stopped being true,
# confidently, and building on it.
#
# So every fact carries ANCHORS: the file it is about and the blob hash that file had
# when the fact was recorded. Staleness is then COMPUTED at read time — the anchor's
# blob no longer matches, or the file has changed N times since — never written by a
# hook. That difference matters more than it looks:
#
#   - nothing to keep in sync, so nothing can drift out of sync;
#   - no writes on the hot path of editing;
#   - and no field an agent can flip to make an inconvenient fact look current.
#
# It is the SKILL's own level 5: derive the value from a single source, and divergence
# becomes impossible rather than merely discouraged.
#
# Classes, and why they expire differently:
#   decision  — a choice a human made. Holds until explicitly revoked; a decision does
#               not stop being the decision because the code moved.
#   inference — something someone (usually an agent) worked out. Expires: it was a
#               reading of code that has since changed.
#   incident  — something that actually broke. Never expires. The whole point of a scar.
#
# `--provenance agent` decisions expire like inferences (`memory.agentDecisionsExpire`).
# An agent must not be able to make its own conclusion immortal by filing it as a
# decision — that is how a guess becomes policy.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "memory: lib.sh not found" >&2; exit 1; }

MEMDIR=".proofgate"
LEDGER="$MEMDIR/memory.jsonl"
TTL_DEFAULT="$(cfg '.memory.ttlDiffs')"; TTL_DEFAULT="${TTL_DEFAULT:-20}"
AGENT_EXPIRES="$(cfg '.memory.agentDecisionsExpire')"; AGENT_EXPIRES="${AGENT_EXPIRES:-true}"

die() { echo "❌ memory: $1" >&2; exit 2; }
fld() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed -e "s/^\"$2\":\"//" -e 's/"$//'; }

cmd_add() {
  local fact="" klass="" prov="agent" anchors="" ttl="" guard="" resolves=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --fact) shift; fact="${1:-}" ;;
      --class) shift; klass="${1:-}" ;;
      --provenance) shift; prov="${1:-}" ;;
      --anchor) shift; anchors="$anchors ${1:-}" ;;
      --ttl-diffs) shift; ttl="${1:-}" ;;
      --guard) shift; guard="${1:-}" ;;
      --resolves) shift; resolves="${1:-}" ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done
  [ -n "$fact" ] || die "--fact is required"
  case "$klass" in decision|inference|incident) ;; *) die "--class must be decision, inference or incident" ;; esac
  case "$prov" in human|agent) ;; *) die "--provenance must be human or agent" ;; esac
  [ -n "$anchors" ] || die "--anchor <path> is required: a fact with nothing to anchor it to can never be shown to have gone stale, which is the only thing that makes memory safe to trust."
  ttl="${ttl:-$TTL_DEFAULT}"

  local anch=""
  for a in $anchors; do
    local ap="${a%%:*}" al="${a##*:}"; [ "$al" = "$ap" ] && al=0
    [ -e "$ap" ] || die "--anchor '$ap' does not exist"
    local blob line_sha=""
    blob="$(pg_sha1 "$ap")"
    if [ "${al:-0}" != 0 ] && [ -f "$ap" ]; then
      line_sha="$(sed -n "${al}p" "$ap" 2>/dev/null | pg_sha1)"
    fi
    anch="${anch:+$anch,}{\"path\":\"$(pg_json_escape "$ap")\",\"blob\":\"$blob\",\"line\":${al:-0},\"line_sha\":\"$line_sha\"}"
  done

  local id; id="m-$(printf '%s|%s|%s' "$fact" "$(pg_now)" "$RANDOM" | pg_sha1 | cut -c1-8)"
  local body
  body="{\"id\":\"$id\",\"ts\":\"$(pg_now)\",\"event\":\"add\",\"ref\":null"
  body="$body,\"fact\":\"$(pg_json_escape "$fact")\",\"class\":\"$klass\",\"provenance\":\"$prov\""
  body="$body,\"anchors\":[$anch],\"created_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"ttl_diffs\":$ttl"
  body="$body,\"guard\":$([ -n "$guard" ] && printf '"%s"' "$guard" || echo null)"
  body="$body,\"resolves\":$([ -n "$resolves" ] && printf '"%s"' "$resolves" || echo null),\"via\":\"memory.sh\""
  mkdir -p "$MEMDIR"
  pg_ledger_append "$LEDGER" "$body"
  echo "✅ $id recorded ($klass, $prov)"

  # An incident is a scar. It opens a lesson that stays open until a guard, a test or a
  # memory entry answers it — writing it down is level 2, and level 2 is the anti-pattern
  # the SKILL names: it protects nothing on its own.
  if [ "$klass" = "incident" ]; then
    pg_lesson_add incident "$id" "$fact" >/dev/null
    echo "   ▫️  a lesson is now OPEN for this incident. It stays open (and the gate keeps"
    echo "       saying so) until something enforces it: a guard in guards.d, a regression"
    echo "       test, or a memory entry with --resolves. Writing it down stores it; only a"
    echo "       guard enforces it."
  fi
  [ -n "$resolves" ] && { pg_lesson_resolve "$resolves" memory "$id"; echo "   ✅ lesson $resolves resolved by $id"; }
  [ -n "$guard" ] && command -v pg_calib >/dev/null 2>&1 && pg_calib "$guard" scar "memory $id"
}

cmd_revoke() {
  local id="${1:-}" reason=""; shift 2>/dev/null || true
  while [ $# -gt 0 ]; do case "$1" in --reason) shift; reason="${1:-}" ;; esac; shift; done
  [ -n "$id" ] || die "revoke needs an id"
  grep -q "\"id\":\"$id\"" "$LEDGER" 2>/dev/null || die "no memory $id"
  [ -n "$reason" ] || die "revoke needs --reason: a decision reversed without a recorded reason is how the same argument gets had again in six months"
  pg_ledger_append "$LEDGER" "{\"id\":\"r-$(printf '%s' "$id" | cut -c3-)\",\"ts\":\"$(pg_now)\",\"event\":\"revoke\",\"ref\":\"$id\",\"fact\":\"$(pg_json_escape "$reason")\",\"class\":\"decision\",\"provenance\":\"human\",\"anchors\":[],\"created_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"ttl_diffs\":0,\"guard\":null,\"resolves\":null,\"via\":\"memory.sh\""
  echo "✅ $id revoked"
}

# status_of <row> → valid | stale | revoked. DERIVED, never stored.
status_of() {
  local row="$1" id klass prov created ttl
  id="$(fld "$row" id)"; klass="$(fld "$row" class)"; prov="$(fld "$row" provenance)"
  created="$(fld "$row" created_sha)"
  ttl="$(printf '%s' "$row" | grep -o '"ttl_diffs":[0-9]*' | head -1 | sed 's/^"ttl_diffs"://')"

  grep -q "\"event\":\"revoke\",\"ref\":\"$id\"" "$LEDGER" 2>/dev/null && { printf 'revoked'; return; }
  [ "$klass" = "incident" ] && { printf 'valid'; return; }

  # Anchor drift: the file this fact is ABOUT is no longer the file it was recorded
  # against. That is the honest signal — not a timestamp, not a TTL guess.
  local a_paths a_blobs i=0
  a_paths="$(printf '%s' "$row" | grep -o '"path":"[^"]*"' | sed -e 's/^"path":"//' -e 's/"$//')"
  a_blobs="$(printf '%s' "$row" | grep -o '"blob":"[^"]*"' | sed -e 's/^"blob":"//' -e 's/"$//')"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i=$((i + 1))
    local recorded current
    recorded="$(printf '%s\n' "$a_blobs" | sed -n "${i}p")"
    current="$(pg_sha1 "$p")"
    [ -n "$current" ] || { printf 'stale'; return; }        # the file is gone
    [ "$recorded" = "$current" ] || { printf 'stale'; return; }
  done <<EOF
$a_paths
EOF

  # A decision holds until revoked — unless an AGENT filed it, in which case it expires
  # like the inference it really is.
  if [ "$klass" = "decision" ]; then
    if [ "$prov" = "human" ] || [ "$AGENT_EXPIRES" != "true" ]; then printf 'valid'; return; fi
  fi

  # Inference TTL: how many commits have touched the anchored files since.
  if [ "${ttl:-0}" -gt 0 ] && [ "$created" != "unknown" ]; then
    local n=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      local c; c="$(git rev-list --count "$created"..HEAD -- "$p" 2>/dev/null || echo 0)"
      [ "${c:-0}" -gt "$n" ] && n="$c"
    done <<EOF
$a_paths
EOF
    [ "$n" -ge "$ttl" ] && { printf 'stale'; return; }
  fi
  printf 'valid'
}

cmd_recall() {
  local target="" changed=0 include_stale=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --changed) changed=1 ;;
      --include-stale) include_stale=1 ;;
      *) target="$1" ;;
    esac
    shift
  done
  [ -f "$LEDGER" ] || return 0

  local paths=""
  if [ "$changed" = 1 ]; then
    local base
    base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -n "$base" ] && base="$(git merge-base "origin/$base" HEAD 2>/dev/null || true)"
    [ -z "$base" ] && base="$(git rev-parse HEAD~1 2>/dev/null || true)"
    paths="$(git diff --name-only "${base:-HEAD}" 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)"
  fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in *'"event":"add"'*) ;; *) continue ;; esac
    local rpaths; rpaths="$(printf '%s' "$row" | grep -o '"path":"[^"]*"' | sed -e 's/^"path":"//' -e 's/"$//')"
    if [ -n "$target" ]; then
      printf '%s\n' "$rpaths" | grep -Fxq "$target" || continue
    elif [ "$changed" = 1 ]; then
      local hit=0
      while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$paths" | grep -Fxq "$p" && hit=1; done <<EOF
$rpaths
EOF
      [ "$hit" = 1 ] || continue
    fi
    local st; st="$(status_of "$row")"
    [ "$st" = "revoked" ] && continue
    [ "$st" = "stale" ] && [ "$include_stale" = 0 ] && {
      printf '  [STALE] %s — %s\n' "$(fld "$row" id)" "$(fld "$row" fact)"
      printf '          the code it was anchored to has changed; re-verify before relying on it\n'
      continue
    }
    printf '  [%s/%s] %s — %s\n' "$(fld "$row" class)" "$(fld "$row" provenance)" "$(fld "$row" id)" "$(fld "$row" fact)"
  done < "$LEDGER"
}

cmd_list() {
  local only_stale=0
  while [ $# -gt 0 ]; do case "$1" in --stale) only_stale=1 ;; esac; shift; done
  [ -f "$LEDGER" ] || return 0
  while IFS= read -r row; do
    case "$row" in *'"event":"add"'*) ;; *) continue ;; esac
    local st; st="$(status_of "$row")"
    [ "$only_stale" = 1 ] && [ "$st" != "stale" ] && continue
    printf '%s  %-9s %-6s %-7s %s\n' "$(fld "$row" id)" "$(fld "$row" class)" "$(fld "$row" provenance)" "$st" "$(fld "$row" fact)"
  done < "$LEDGER"
}

cmd_show() {
  local id="${1:-}"; [ -n "$id" ] || die "show needs an id"
  local row; row="$(grep "\"id\":\"$id\"" "$LEDGER" 2>/dev/null | head -1)"
  [ -n "$row" ] || die "no memory $id"
  printf '%s\n' "$row"
  printf 'status: %s\n' "$(status_of "$row")"
}

# gc drops what has genuinely expired. Deliberately explicit and never automatic: this
# file is committed, so a silent rewrite would land in someone's diff unannounced.
cmd_gc() {
  [ -f "$LEDGER" ] || return 0
  local tmp; tmp="$(mktemp)" ; local dropped=0
  while IFS= read -r row; do
    case "$row" in *'"event":"add"'*)
      local st; st="$(status_of "$row")"
      if [ "$st" = "stale" ] && [ "$(fld "$row" class)" = "inference" ]; then dropped=$((dropped + 1)); continue; fi
      ;;
    esac
    printf '%s\n' "$row" >> "$tmp"
  done < "$LEDGER"
  : > "$LEDGER"
  while IFS= read -r r; do pg_ledger_append "$LEDGER" "$(printf '%s' "$r" | sed -e 's/,"prev":"[^"]*"}$//')"; done < "$tmp"
  rm -f "$tmp"
  echo "✅ dropped $dropped stale inference(s); decisions and incidents kept"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  recall) shift; cmd_recall "$@" ;;
  revoke) shift; cmd_revoke "$@" ;;
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  gc) shift; cmd_gc "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (add|recall|revoke|list|show|gc)" ;;
esac
