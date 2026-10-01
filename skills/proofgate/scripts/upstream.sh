#!/usr/bin/env bash
# ProofGate — the way BACK. What a project learned while using the gate, returned to the gate.
#
# Usage:
#   upstream.sh status [--quiet]                  offline: what THIS copy learned since it was installed
#   upstream.sh diff <clone>|github               against an upstream checkout: local-only / diverged / behind
#   upstream.sh send <clone> [guard-name...]      copy guards learned here into the clone's guards.d
#   upstream.sh lock <scripts-dir> [version]      (installer) record what upstream shipped, hash by hash
#   upstream.sh keep-list <scripts-dir>           (installer) what an upgrade must NOT overwrite
#
# WHY this exists — the scar:
#
# The rule "an error becomes a guard in ChrnX0/proofgate, with a positive and a negative
# test, and goes up by PR" lived in a project's CLAUDE.md. Prose. The skill's own ladder
# says prose protects nothing (level 2), and it did not: measured on 2026-09-30, the
# heaviest user of this tool held six guards, a `cfg` that stops swallowing `false`, a
# `pg_match` that took the gate from ~8 min to 22 s and two false-positive fixes — all
# committed and tested THERE, none of it here. Three mechanical causes, each closed:
#
#   no trigger        → guards.d/91-upstream-drift warns on every gate run while this
#                       copy holds something upstream does not
#   lesson stays put  → `diff` lists it, `send` stages it in a clone with the scar as the
#                       PR body's first paragraph
#   installer erased  → install.sh used to `rm -rf guards.d`; a guard that existed only
#                       in the project would have died on the next upgrade. `keep-list`
#                       is what install.sh now consults before overwriting anything
#
# The lock (`.proofgate/upstream.lock`) holds the hash of every file AS UPSTREAM SHIPPED
# IT. That is what makes the comparison three-way: local == lock means "untouched, upstream
# moved" (safe to overwrite); upstream == lock means "we are ahead" (send it back); neither
# means both moved (merge by hand). Without a lock — a copy installed before this existed —
# direction is `unknown` and the conservative rule applies: never overwrite what differs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL="${PG_LOCAL_DIR:-$SCRIPT_DIR}"
LOCK="$LOCAL/upstream.lock"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/lib.sh" ] && . "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null

die() { echo "❌ upstream: $1" >&2; exit 2; }
hash_of() { git hash-object -- "$1" 2>/dev/null; }

# index <dir> → "key<TAB>relpath<TAB>hash" for every vendored file. A guard's key drops the
# NN- prefix: the number is only execution order, and upstream renumbers by subject — two
# copies of one guard under different numbers would otherwise run twice and count twice.
index() {
  local d="$1" f rel key
  for f in "$d"/*.sh "$d"/*.mjs "$d"/guards.d/*.sh; do
    [ -f "$f" ] || continue
    rel="${f#"$d"/}"
    case "$rel" in
      guards.d/TEMPLATE*) continue ;;
      guards.d/*) key="guards.d/$(printf '%s' "${rel#guards.d/}" | sed -E 's/^[0-9]+-//')" ;;
      *) key="$rel" ;;
    esac
    printf '%s\t%s\t%s\n' "$key" "$rel" "$(hash_of "$f")"
  done
}

# classify <upstream-scripts-dir> → state<TAB>local<TAB>upstream<TAB>direction
classify() {
  local up="$1" L U; L="$(mktemp)"; U="$(mktemp)"
  index "$LOCAL" > "$L"; index "$up" > "$U"
  awk -F'\t' -v lock="$LOCK" '
    BEGIN { while ((getline line < lock) > 0) { if (line ~ /^#/) continue; split(line, a, "  "); lk[a[2]] = a[1] } }
    NR == FNR { ukey[$1] = 1; uhash[$1] = $3; upath[$1] = $2; next }
    { seen[$1] = 1
      if (!($1 in ukey)) { print "local-only\t" $2 "\t-\t-"; next }
      if (uhash[$1] == $3) { print "same\t" $2 "\t" upath[$1] "\t-"; next }
      dir = "unknown"
      if ($2 in lk) { if (lk[$2] == $3) dir = "behind"; else if (lk[$2] == uhash[$1]) dir = "ahead"; else dir = "both" }
      print "diverged\t" $2 "\t" upath[$1] "\t" dir }
    END { for (k in ukey) if (!(k in seen)) print "upstream-only\t-\t" upath[k] "\t-" }
  ' "$U" "$L" | sort
  rm -f "${L:?}" "${U:?}"
}

# Resolve "<clone>|github" to the upstream scripts dir. Sets UP (and TMP_UP for cleanup).
resolve_upstream() {
  local src="${1:-}"; UP=""; TMP_UP=""
  [ -n "$src" ] || die "give a proofgate checkout (or 'github')"
  if [ "$src" = github ]; then
    TMP_UP="$(mktemp -d)"
    curl -fsSL https://github.com/ChrnX0/proofgate/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP_UP" || die "could not fetch upstream"
    src="$TMP_UP/proofgate-main"
  fi
  UP="$src/skills/proofgate/scripts"
  [ -f "$UP/verify.sh" ] || die "$src is not a proofgate checkout (no skills/proofgate/scripts/verify.sh)"
}

keep_local_names() { command -v cfg_list >/dev/null 2>&1 && cfg_list '.upstream.keepLocal' 2>/dev/null; }

cmd_status() {
  local quiet=0 L rows; [ "${1:-}" = "--quiet" ] && quiet=1
  [ -f "$LOCK" ] || { [ "$quiet" = 1 ] && exit 0; echo "▫️  no upstream.lock — this copy predates it; run 'upstream.sh diff <clone>' (direction will be unknown)"; exit 0; }
  L="$(mktemp)"; index "$LOCAL" > "$L"
  rows="$(awk -F'\t' -v lock="$LOCK" '
    BEGIN { while ((getline line < lock) > 0) { if (line ~ /^#/) continue; split(line, a, "  "); lk[a[2]] = a[1] } }
    { if (!($2 in lk)) print "new\t" $2; else if (lk[$2] != $3) print "modified\t" $2 }' "$L" | sort)"
  rm -f "$L"
  # keepLocal: files the project declares as its own on purpose — never reported.
  local keep; keep="$(keep_local_names || true)"
  if [ -n "$keep" ] && [ -n "$rows" ]; then
    rows="$(printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r st rel; do
      printf '%s\n' "$keep" | grep -Fxq "$(basename "$rel")" || printf '%s\t%s\n' "$st" "$rel"
    done)"
  fi
  if [ "$quiet" = 1 ]; then [ -n "$rows" ] && printf '%s\n' "$rows"; exit 0; fi
  [ -n "$rows" ] || { echo "✅ nothing learned here that upstream lacks"; exit 0; }
  printf '%s\n' "$rows" | sed 's/^/  /'
  echo "  → 'upstream.sh diff <clone>' then 'upstream.sh send <clone>' — or list a project-specific one under upstream.keepLocal in proofgate.json"
}

cmd_diff() {
  resolve_upstream "${1:-}"
  local out send=0 behind=0 lo=0 both=0
  out="$(classify "$UP")"
  echo "upstream diff — $LOCAL  vs  $UP"
  printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r st l u d; do
    case "$st" in
      same) ;;
      local-only) echo "  local-only     $l        ← learned here, never sent back" ;;
      diverged) echo "  diverged       $l ≠ $u   [$d]" ;;
      upstream-only) echo "  upstream-only  $u        ← this copy is behind" ;;
    esac
  done
  lo="$(printf '%s\n' "$out" | grep -c '^local-only' || true)"
  both="$(printf '%s\n' "$out" | grep -E '^diverged' | grep -vc 'behind$' || true)"
  behind="$(printf '%s\n' "$out" | grep -c '^upstream-only' || true)"
  send=$((lo + both))
  echo "  ── ${lo} local-only · ${both} diverged-not-behind · ${behind} upstream-only"
  [ -n "$TMP_UP" ] && rm -rf "${TMP_UP:?}"
  [ "$send" -gt 0 ] && exit 1
  exit 0
}

cmd_send() {
  local clone="${1:-}"; shift || true
  resolve_upstream "$clone"
  local dest="$UP/guards.d" l name stripped pfx final want n
  [ -d "$dest" ] || die "$dest does not exist"
  classify "$UP" | grep -E "^local-only$(printf '\t')guards\\.d/" | while IFS="$(printf '\t')" read -r _ l _ _; do
    name="$(basename "$l")"
    if [ "$#" -gt 0 ]; then
      want=0; for w in "$@"; do [ "$w" = "$name" ] || [ "$w" = "${name#*-}" ] && want=1; done
      [ "$want" = 1 ] || continue
    fi
    pfx="${name%%-*}"; stripped="${name#*-}"; final="$name"
    # Prefix taken by another guard upstream? Take the next free one — the number is only order.
    if ls "$dest/${pfx}-"*.sh >/dev/null 2>&1; then
      n=$((10#$pfx + 1))
      while [ "$n" -le 98 ] && ls "$dest/$(printf '%02d' "$n")-"*.sh >/dev/null 2>&1; do n=$((n + 1)); done
      # No free slot left: keep the original number. Two guards may share one — it is only order.
      [ "$n" -le 98 ] && final="$(printf '%02d' "$n")-$stripped"
    fi
    cp "$LOCAL/$l" "$dest/$final" && chmod +x "$dest/$final"
    echo "  sent  $l → guards.d/$final"
    echo "        PR body, first paragraph (the scar — from the guard's own header):"
    sed -n '2,$p' "$dest/$final" | awk '/^#/ { sub(/^# ?/, ""); print "          " $0; next } { exit }'
  done
  [ -n "$TMP_UP" ] && rm -rf "${TMP_UP:?}"
  cat <<'EOF'
  A sent guard is a DRAFT until it has, in the clone:
    1. a positive AND a negative case in tests/run-tests.sh (CONTRIBUTING.md step 4)
    2. the guard count updated where the docs state it (a test fails on drift)
    3. a CHANGELOG entry that tells the scar
  Then open the PR. Diverged files (lib.sh, verify.sh, changed guards) are NOT sent:
  merge them by hand — 'upstream.sh diff' says which way each one moved.
EOF
}

cmd_lock() {
  local src="${1:-}" ver="${2:-unknown}"
  [ -f "$src/verify.sh" ] || die "lock needs the scripts dir upstream shipped"
  mkdir -p "$LOCAL"
  { printf '# proofgate %s — what upstream shipped, hash by hash (%s)\n' "$ver" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    index "$src" | awk -F'\t' '{ print $3 "  " $2 }'
  } > "$LOCK"
}

# keep-list <scripts-dir> → local<TAB>upstream-counterpart: what an upgrade must not overwrite.
cmd_keep_list() {
  local src="${1:-}"; [ -f "$src/verify.sh" ] || die "keep-list needs the new scripts dir"
  classify "$src" | awk -F'\t' '
    $1 == "local-only" { print $2 "\t-" }
    $1 == "diverged" && $4 != "behind" { print $2 "\t" $3 }'
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  diff) shift; cmd_diff "$@" ;;
  send) shift; cmd_send "$@" ;;
  lock) shift; cmd_lock "$@" ;;
  keep-list) shift; cmd_keep_list "$@" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
