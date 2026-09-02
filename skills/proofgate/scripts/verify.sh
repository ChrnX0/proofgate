#!/usr/bin/env bash
# ProofGate — the MECHANICAL gate. The half of the checklist a machine checks
# better than judgment. Judgment lives in SKILL.md; guards live in guards.d/.
#
# Usage:
#   bash verify.sh                    # fast gate (no build)
#   bash verify.sh --build            # include the build (pre-release)
#   bash verify.sh --strict           # warnings become failures
#   bash verify.sh --smoke            # also run the production smoke checks (config.smoke)
#   bash verify.sh --json             # print the verdict as JSON to stdout (logs → stderr)
#   bash verify.sh --only <guard>     # run a single guard by name (no verdict written)
#   bash verify.sh --dry-run          # show what would run, run nothing
#   bash verify.sh --base <ref>       # diff base (default: merge-base with origin default branch)
#   bash verify.sh --report <file>    # also write a markdown report
#   bash verify.sh --no-impact        # skip the blast-radius computation
#
# Exit codes: 0 = gate passed (warnings allowed unless --strict) · 1 = gate FAILED.
#
# Every full run writes a machine-readable verdict to
#   $(git rev-parse --git-dir)/proofgate-verdict.json
# (inside .git, so it is never committed). The push-guard hook reads it to refuse a
# push whose HEAD has no fresh passing verdict — see hooks/push-guard.sh.
#
# Optional config: proofgate.json at the repo root (all keys optional). See
# examples/proofgate.json for the full reference. Read with jq, or node, or
# python3 — whichever exists (zero hard dependency).
set -uo pipefail

# ── flags ────────────────────────────────────────────────────────────────────
BUILD=0 STRICT=0 DRY=0 JSON=0 SMOKE=0 ONLY="" BASE_REF="" REPORT="" NOIMPACT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD=1 ;;
    --strict) STRICT=1 ;;
    --smoke) SMOKE=1 ;;
    --json) JSON=1 ;;
    --dry-run) DRY=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    --base) shift; BASE_REF="${1:-}" ;;
    --report) shift; REPORT="${1:-}" ;;
    --no-impact) NOIMPACT=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDS_DIR="$SCRIPT_DIR/guards.d"
IMPACT_SH="$SCRIPT_DIR/impact.sh"
CLAIM_SH="$SCRIPT_DIR/claim.sh"
CFG="proofgate.json"
export PROOFGATE_CFG="$CFG" PROOFGATE_LIB="$SCRIPT_DIR/lib.sh"
# shellcheck source=/dev/null
[ -f "$PROOFGATE_LIB" ] && . "$PROOFGATE_LIB"
command -v cfg >/dev/null 2>&1 || cfg() { :; }   # ultra-degraded: no lib, no config

TMO="$(cfg '.timeoutSeconds' 2>/dev/null)"; TMO="${TMO:-900}"

# ── output + verdict accumulation ────────────────────────────────────────────
FAILS=0 WARNS=0 LINES=""
CHECK_JSON=""   # comma-joined JSON objects for the verdict
say()  { if [ "$JSON" = 1 ]; then printf '%s\n' "$1" >&2; else printf '%s\n' "$1"; fi; LINES="${LINES}${1}"$'\n'; }
_slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-.*$//'; }
record() { # record <name> <status> <detail>
  local o; o="{\"name\":\"$(pg_json_escape "$1")\",\"status\":\"$2\",\"detail\":\"$(pg_json_escape "$3")\"}"
  CHECK_JSON="${CHECK_JSON:+$CHECK_JSON,}$o"
}
gh_annot() { # gh_annot <error|warning> <msg> — GitHub Actions annotation
  { [ -n "${GITHUB_ACTIONS:-}" ] && [ "$JSON" != 1 ]; } || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  printf '::%s ::%s\n' "$1" "$m"
}
ok()   { say "✅ $1"; record "${2:-$(_slug "$1")}" pass "$1"; }
warn() { say "⚠️  $1"; WARNS=$((WARNS + 1)); record "${2:-$(_slug "$1")}" warn "$1"; gh_annot warning "$1"; }
fail() { say "❌ $1"; FAILS=$((FAILS + 1)); record "${2:-$(_slug "$1")}" fail "$1"; gh_annot error "$1"; }
note() { say "▫️  $1"; record "${2:-$(_slug "$1")}" note "$1"; }

with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout --foreground "$TMO" "$@"; else "$@"; fi; }
run_step() { # run_step <label> <command...>
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then note "would run [$label]: $*"; return 0; fi
  local log; log="$(mktemp)"
  if with_timeout "$@" >"$log" 2>&1; then ok "$label"
  else
    local code=$?; local extra=""; [ "$code" = 124 ] && extra=" (timed out after ${TMO}s)"
    fail "$label BROKEN$extra — last lines:"; tail -5 "$log" | sed 's/^/     /'
  fi
  rm -f "$log"
}

say "── ProofGate · mechanical gate ─────────────────────────────"
[ -f "$(pg_git_dir 2>/dev/null || echo .git)/proofgate-mode" ] && \
  note "PROTOTYPE MODE is on — the edit- and stop-guards are relaxed and claims are capped at E1. This verdict records mode:prototype; the push is still gated." mode

# ── diff base, resolved ONCE and up front ────────────────────────────────────
# It used to be resolved just before the guards. Impact has to know the range
# before the first command runs (it decides the required evidence level, which the
# verdict reports), and two places computing "the base" independently is exactly
# the divergence this project keeps finding in other people's code.
if [ -z "$BASE_REF" ]; then
  DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -z "$DEFAULT_BRANCH" ] && for b in main master; do git rev-parse "origin/$b" >/dev/null 2>&1 && { DEFAULT_BRANCH="$b"; break; }; done
  [ -n "$DEFAULT_BRANCH" ] && BASE_REF="$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || true)"
fi

# ── blast radius (impact.sh) ─────────────────────────────────────────────────
# One measurement, many consumers: the required evidence level, whether a skeptic
# pass is mandatory, what the skeptic reads, and which memory the change stales.
# It is a NOTE, never a warning: a low-confidence backend is a fact about the
# machine, not a defect in the delivery, and a warning printed on every run of
# every repo without ctags would be wallpaper within a day.
IMPACT_JSON="$(pg_git_dir 2>/dev/null || echo .git)/proofgate-impact.json"
RISK="" REQUIRED_LEVEL="" MAX_LEVEL="" SKEPTIC_REQ="" NAV_BACKEND="" NAV_CONF="" IMPACT_DEGR=""
if [ "$NOIMPACT" != 1 ] && [ -z "$ONLY" ] && [ -f "$IMPACT_SH" ] && command -v pg_scalar >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then
    note "would compute impact (blast radius)" impact
  else
    with_timeout bash "$IMPACT_SH" ${BASE_REF:+--base "$BASE_REF"} </dev/null >/dev/null 2>&1 || true
    if [ -f "$IMPACT_JSON" ]; then
      RISK="$(pg_scalar "$IMPACT_JSON" risk_class)"
      REQUIRED_LEVEL="$(pg_scalar "$IMPACT_JSON" required_level)"
      MAX_LEVEL="$(pg_scalar "$IMPACT_JSON" max_achievable_level)"
      SKEPTIC_REQ="$(pg_scalar "$IMPACT_JSON" skeptic_required)"
      NAV_BACKEND="$(pg_scalar "$IMPACT_JSON" navigation_backend)"
      NAV_CONF="$(pg_scalar "$IMPACT_JSON" navigation_confidence)"
      IMPACT_DEGR="$(grep -o '"code":"[^"]*"' "$IMPACT_JSON" 2>/dev/null | sed -e 's/^"code":"//' -e 's/"$//' | tr '\n' ' ')"
      export PROOFGATE_IMPACT="$IMPACT_JSON"
      note "impact: ${RISK:-?} · $(pg_scalar "$IMPACT_JSON" files_n) file(s) · $(pg_scalar "$IMPACT_JSON" symbols_n) symbol(s) · $(pg_scalar "$IMPACT_JSON" callers_n) caller(s) · needs ${REQUIRED_LEVEL:-?} · nav ${NAV_BACKEND:-?} (${NAV_CONF:-?})${IMPACT_DEGR:+ · declared: $IMPACT_DEGR}" impact
      if [ "$SKEPTIC_REQ" = "true" ]; then
        note "impact: this diff is $RISK — an adversarial pass is REQUIRED before 'done' ($(pg_json "$IMPACT_JSON" '.risk_reasons[0]' 2>/dev/null | head -c 120))" impact-skeptic
      fi
    fi
  fi
fi

# ── stack detection + configured commands ───────────────────────────────────
PM=""
if   [ -f pnpm-lock.yaml ];      then PM="pnpm"
elif [ -f yarn.lock ];           then PM="yarn"
elif [ -f bun.lockb ] || [ -f bun.lock ]; then PM="bun"
elif [ -f package-lock.json ] || [ -f package.json ]; then PM="npm"
fi
has_script() { [ -n "$PM" ] && [ -f package.json ] && grep -q "\"$1\"[[:space:]]*:" package.json; }

run_named() { # run_named <name> — configured command wins; else auto-detected
  local name="$1" custom
  custom="$(cfg ".commands.$name")"
  if [ -n "$custom" ]; then run_step "$name (proofgate.json)" bash -c "$custom"; return; fi
  case "$name" in
    typecheck)
      if has_script typecheck; then run_step "typecheck ($PM)" "$PM" run typecheck
      elif [ -f Cargo.toml ]; then run_step "typecheck (cargo check)" cargo check --quiet
      elif [ -f go.mod ]; then run_step "typecheck (go vet)" go vet ./...
      elif [ -f pyproject.toml ] && command -v mypy >/dev/null 2>&1; then run_step "typecheck (mypy)" mypy .
      elif ls ./*.sln >/dev/null 2>&1 || ls ./*.csproj >/dev/null 2>&1; then run_step "typecheck (dotnet build)" dotnet build --nologo
      elif [ -f mix.exs ]; then run_step "typecheck (mix compile)" mix compile --warnings-as-errors
      elif [ -f deno.json ] || [ -f deno.jsonc ]; then run_step "typecheck (deno check)" deno check .
      else note "no typecheck detected (add commands.typecheck to proofgate.json)"; fi ;;
    lint)
      if has_script lint; then run_step "lint ($PM)" "$PM" run lint
      elif [ -f pyproject.toml ] && command -v ruff >/dev/null 2>&1; then run_step "lint (ruff)" ruff check .
      else note "no lint detected (add commands.lint to proofgate.json)"; fi ;;
    test)
      if has_script test; then run_step "tests ($PM)" "$PM" test
      elif [ -f Cargo.toml ]; then run_step "tests (cargo)" cargo test --quiet
      elif [ -f go.mod ]; then run_step "tests (go)" go test ./...
      elif [ -f pyproject.toml ] && command -v pytest >/dev/null 2>&1; then run_step "tests (pytest)" pytest -q
      elif [ -f Gemfile ] && [ -d spec ]; then run_step "tests (rspec)" bundle exec rspec
      elif [ -f Gemfile ]; then run_step "tests (rake)" bundle exec rake test
      elif [ -f composer.json ] && grep -q '"test"' composer.json; then run_step "tests (composer)" composer test
      elif [ -f mix.exs ]; then run_step "tests (mix)" mix test
      elif ls ./*.sln >/dev/null 2>&1 || ls ./*.csproj >/dev/null 2>&1; then run_step "tests (dotnet)" dotnet test --nologo
      elif { [ -f deno.json ] || [ -f deno.jsonc ]; } ; then run_step "tests (deno)" deno test -A
      elif [ -f ./gradlew ]; then run_step "tests (gradle)" ./gradlew test
      elif [ -f pom.xml ] && { [ -f ./mvnw ] || command -v mvn >/dev/null 2>&1; }; then run_step "tests (maven)" bash -c '[ -f ./mvnw ] && ./mvnw -q test || mvn -q test'
      else note "no test runner detected (add commands.test to proofgate.json)"; fi ;;
    build)
      if has_script build; then run_step "build ($PM)" "$PM" run build
      elif [ -f Cargo.toml ]; then run_step "build (cargo)" cargo build --quiet
      elif [ -f go.mod ]; then run_step "build (go)" go build ./...
      elif [ -f mix.exs ]; then run_step "build (mix)" mix compile
      elif [ -f ./gradlew ]; then run_step "build (gradle)" ./gradlew build -x test
      elif [ -f pom.xml ] && { [ -f ./mvnw ] || command -v mvn >/dev/null 2>&1; }; then run_step "build (maven)" bash -c '[ -f ./mvnw ] && ./mvnw -q -DskipTests package || mvn -q -DskipTests package'
      else note "no build detected (add commands.build to proofgate.json)"; fi ;;
  esac
}

# ── --only: run a single guard, no verdict written (D3) ──────────────────────
if [ -n "$ONLY" ]; then
  BASE_REF="${BASE_REF:-$(git merge-base "origin/$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo main)" HEAD 2>/dev/null || git rev-parse HEAD~1 2>/dev/null)}"
  export PROOFGATE_BASE="$BASE_REF"
  # --only must look everywhere a full run looks, including the project's own
  # guardsDirs. Searching only the engine's guards.d made project guards
  # unreachable in isolation — so the guard a maintainer most wants to iterate on
  # (the one they just wrote) was the one --only could not run, and confirming it
  # had even EXECUTED meant digging through the verdict ledger.
  ONLY_DIRS="$GUARDS_DIR"
  while IFS= read -r d; do [ -n "$d" ] && [ -d "$d" ] && ONLY_DIRS="$ONLY_DIRS
$d"; done <<EOF
$(cfg_list '.guardsDirs' 2>/dev/null)
EOF
  while IFS= read -r gdir; do
    [ -n "$gdir" ] && [ -d "$gdir" ] || continue
    for guard in "$gdir"/*.sh; do
      [ -f "$guard" ] || continue
      gname="$(basename "$guard" .sh | sed -E 's/^[0-9]+-//')"
      [ "$gname" = "$ONLY" ] || continue
      OUT="$(with_timeout bash "$guard" 2>&1)"; CODE=$?
      printf '%s\n' "$OUT"
      exit "$( [ "$CODE" = 1 ] && echo 1 || echo 0 )"
    done
  done <<EOF
$ONLY_DIRS
EOF
  echo "no guard named '$ONLY' (looked in: $(echo "$ONLY_DIRS" | tr '\n' ' '))" >&2; exit 1
fi

run_named typecheck
run_named lint
run_named test
if [ "$BUILD" = 1 ]; then run_named build; else note "build NOT run (use --build before releasing)"; fi

# ── git: committed (FAIL) AND pushed (WARN — the push itself is what's gated) ─
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  ok "working tree clean (everything committed)" "git-committed"
else
  fail "UNCOMMITTED changes present — commit before declaring done" "git-committed"
fi
if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ]; then
    ok "HEAD pushed (matches $(git rev-parse --abbrev-ref '@{u}'))" "git-pushed"
  else
    warn "HEAD not pushed yet — the push itself is the gated step (push-guard checks this verdict)" "git-pushed"
  fi
else
  note "branch has no upstream — push with: git push -u origin <branch>" "git-pushed"
fi

# ── production smoke (--smoke): mechanical proof the deployed thing answers ───
if [ "$SMOKE" = 1 ]; then
  SN="$(cfg_len '.smoke' 2>/dev/null || echo 0)"
  if [ "${SN:-0}" -eq 0 ]; then
    note "smoke: no smoke checks configured (add a smoke[] array to proofgate.json)"
  elif ! command -v curl >/dev/null 2>&1; then
    warn "smoke: curl not available — cannot run production smoke" "smoke"
  else
    for i in $(seq 0 $((SN - 1))); do
      sn="$(cfg ".smoke[$i].name")"; su="$(cfg ".smoke[$i].url")"; sc="$(cfg ".smoke[$i].cmd")"
      se="$(cfg ".smoke[$i].expect")"; ss="$(cfg ".smoke[$i].status")"; ss="${ss:-200}"
      if [ -n "$sc" ]; then
        if [ "$DRY" = 1 ]; then note "would smoke [$sn]: $sc"; continue; fi
        if with_timeout bash -c "$sc" >/dev/null 2>&1; then ok "smoke: ${sn:-cmd} ✓" "smoke-${sn:-cmd}"; else fail "smoke: ${sn:-cmd} — command failed" "smoke-${sn:-cmd}"; fi
      elif [ -n "$su" ]; then
        if [ "$DRY" = 1 ]; then note "would smoke [$sn]: GET $su (want $ss${se:+, /$se/})"; continue; fi
        body="$(mktemp)"; code="$(curl -sS --max-time "$TMO" -o "$body" -w '%{http_code}' "$su" 2>/dev/null || echo 000)"
        if [ "$code" = "$ss" ] && { [ -z "$se" ] || grep -Eq -- "$se" "$body"; }; then
          ok "smoke: ${sn:-$su} → $code${se:+ /$se/ ✓}" "smoke-${sn:-url}"
        else
          fail "smoke: ${sn:-$su} → got $code (want $ss)${se:+, body /$se/ not matched}" "smoke-${sn:-url}"
        fi
        rm -f "$body"
      else
        note "smoke[$i]: neither url nor cmd — skipped"
      fi
    done
  fi
fi

# ── guards (guards.d/*.sh + config.guardsDirs, alphabetical) ─────────────────
FIRED=""   # guard names that produced a fail/warn (for the ledger)
if [ -n "$BASE_REF" ] && [ "$BASE_REF" != "$(git rev-parse HEAD)" ]; then
  export PROOFGATE_BASE="$BASE_REF" PROOFGATE_STRICT="$STRICT"
  SKIPS="$(cfg_list '.skip' 2>/dev/null)"
  DIRS="$GUARDS_DIR"
  while IFS= read -r d; do [ -n "$d" ] && [ -d "$d" ] && DIRS="$DIRS
$d"; done <<EOF
$(cfg_list '.guardsDirs' 2>/dev/null)
EOF
  while IFS= read -r gdir; do
    [ -n "$gdir" ] && [ -d "$gdir" ] || continue
    for guard in "$gdir"/*.sh; do
      [ -f "$guard" ] || continue
      gname="$(basename "$guard" .sh | sed -E 's/^[0-9]+-//')"
      # skip / severity:off
      if printf '%s\n' "$SKIPS" | grep -qx "$gname"; then note "guard $gname skipped (proofgate.json)"; continue; fi
      sev="$(cfg ".severity.\"$gname\"")"
      [ "$sev" = "off" ] && { note "guard $gname disabled (severity off)"; continue; }
      if [ "$DRY" = 1 ]; then note "would run guard: $(basename "$guard")"; continue; fi
      OUT="$(with_timeout bash "$guard" 2>&1)"; CODE=$?
      [ "$CODE" = 124 ] && { OUT="⚠️  $gname: timed out after ${TMO}s"; CODE=2; }
      # severity override remaps the counted class (icon in OUT may not match — note it)
      if [ -n "$sev" ] && [ "$sev" != "off" ]; then
        case "$sev" in fail) [ "$CODE" != 0 ] && CODE=1 ;; warn) [ "$CODE" = 1 ] && CODE=2 ;; esac
        note "severity override: $gname → $sev (proofgate.json)"
      fi
      [ -n "$OUT" ] && while IFS= read -r line; do say "$line"; done <<< "$OUT"
      case $CODE in
        0) record "$gname" pass "$OUT" ;;
        1) FAILS=$((FAILS + 1)); FIRED="$FIRED $gname"; record "$gname" fail "$OUT"; gh_annot error "$OUT" ;;
        2) WARNS=$((WARNS + 1)); FIRED="$FIRED $gname"; record "$gname" warn "$OUT"; gh_annot warning "$OUT" ;;
      esac
    done
  done <<EOF
$DIRS
EOF
  # The blind-gate trap. The default base is the merge-base with the default branch — so
  # once the work is fast-forwarded onto it, the base moves WITH the work and the guarded
  # diff shrinks to whatever landed after the promotion (usually a docs commit). Every
  # diff-based guard then prints its reassuring "nothing touched" line: green, and blind,
  # exactly when the delivery was just published. Guards cannot catch this themselves —
  # from inside a guard an empty diff is indistinguishable from a clean one. Only the
  # engine knows how big the diff it handed them was.
  # "How much source is in this diff" is now measured ONCE, by impact.sh, and read
  # back here. It used to be re-derived with a second, narrower rule — a path glob
  # plus a shorter extension list — and the two disagreed: on this very repo impact
  # reported 17 source files while this check reported none, so a gate that had just
  # measured the change announced it had been looking at nothing. Deriving both from
  # one source is the SKILL's own level-5 fix; the old heuristic stays only as the
  # fallback for --no-impact and for a vendored copy without impact.sh.
  if [ -n "${RISK:-}" ] && [ -f "$IMPACT_JSON" ]; then
    SRC_IN_DIFF="$(pg_scalar "$IMPACT_JSON" source_n)"
  else
    SRC_GLOBS="$(cfg '.sourceGlobs')"; SRC_GLOBS="${SRC_GLOBS:-src/|lib/|app/}"
    SRC_IN_DIFF=$(git diff --name-only "$BASE_REF"..HEAD 2>/dev/null \
      | grep -Ev '(guards\.d/|^\.proofgate/)' \
      | grep -E "($SRC_GLOBS)" \
      | grep -Ec '\.(ts|tsx|js|jsx|py|rb|go|rs|java|kt|swift|cs|php)$' || true)
  fi
  if [ "${SRC_IN_DIFF:-0}" -eq 0 ]; then
    warn "sourceless-diff: the guarded diff has NO source file (docs/config only). If you just promoted this work, the diff guards above are BLIND — their ✅ means 'nothing to look at', not 'nothing wrong'. Re-run with --base <sha before the block>." "sourceless-diff"
  fi
else
  warn "empty diff against the default branch (nothing to deliver? or fetch origin first)" "diff-base"
fi

# ── evidence: is the claimed level EARNED, and is it even reachable here? ────
# The mechanical half of the gate can only ever say "nothing I check is broken".
# What the delivery actually CLAIMS lives in the claims ledger, and this is where the
# two meet: required (from the blast radius) vs achieved (from commands that ran).
#
# Three outcomes, deliberately distinct — collapsing them is how gates get disabled:
#   proven       — achieved ≥ required.
#   unproven     — the evidence is missing, and could be produced here.
#   cannot_prove — the evidence is IMPOSSIBLE on this machine (no runtime to drive).
# Only the first two are the author's fault. Failing a delivery for the third would
# fail every delivery on a laptop with no e2e setup, for a reason nobody can fix in
# the diff — which is exactly how a gate earns an alias to `true`.
PROOF_STATUS="unknown" ACHIEVED_LEVEL="" PROOF_MISSING=""
_lvl_n() { case "$1" in E0) echo 0 ;; E1) echo 1 ;; E2) echo 2 ;; E3) echo 3 ;; E4) echo 4 ;; *) echo -1 ;; esac; }
if [ "$DRY" != 1 ] && [ -z "$ONLY" ] && [ -f "$CLAIM_SH" ] && [ -n "$REQUIRED_LEVEL" ]; then
  ACHIEVED_LEVEL="$(bash "$CLAIM_SH" achieved 2>/dev/null </dev/null || echo E0)"
  req_n="$(_lvl_n "$REQUIRED_LEVEL")"; ach_n="$(_lvl_n "$ACHIEVED_LEVEL")"; max_n="$(_lvl_n "${MAX_LEVEL:-E4}")"
  if [ "$ach_n" -ge "$req_n" ]; then
    PROOF_STATUS="proven"
    ok "proof-level: central claim at $ACHIEVED_LEVEL (this change requires $REQUIRED_LEVEL)" "proof-level"
  elif [ "$max_n" -lt "$req_n" ]; then
    PROOF_STATUS="cannot_prove"
    PROOF_MISSING="$(pg_json "$IMPACT_JSON" '.degradations[0].detail' 2>/dev/null)"
    PROOF_MISSING="${PROOF_MISSING:-no way to drive the real runtime from here}"
    # A NOTE by default, not a warning — and the distinction is load-bearing. This is
    # a fact about the machine, not a defect in the delivery: nothing the author can
    # write in this diff makes an absent runtime appear. Emitting a warning would make
    # `--strict` fail every delivery on every box without an e2e setup, which is not
    # rigour, it is how a gate gets aliased to `true`. Repos that DO want it enforced
    # set requireProof, and then it blocks with the capability named.
    _msg="cannot-prove: this change requires $REQUIRED_LEVEL, but only $MAX_LEVEL is reachable here — $PROOF_MISSING. Add commands.e2e or smoke[] to proofgate.json, or say plainly in your status that the runtime claim is UNPROVEN."
    if [ "$(cfg '.requireProof')" = "true" ]; then warn "$_msg" "proof-level"; else note "$_msg" "proof-level"; fi
  else
    PROOF_STATUS="unproven"
    warn "proof-level: this change requires $REQUIRED_LEVEL, the ledger has $ACHIEVED_LEVEL. Record the run that proves it: claim.sh add --claim \"...\" --level $REQUIRED_LEVEL --run \"<cmd>\" --expect \"<marker unique to the new version>\"" "proof-level"
  fi
fi

# ── ledgers: append-only, hash-chained ───────────────────────────────────────
# Every row carries the hash of the row before it, so a line appended or edited by
# hand — the agent writing its own evidence — breaks the chain. This is tamper-
# EVIDENT, not tamper-proof: anything with a shell can recompute the whole chain.
# What it removes is the cheap, deniable edit, and it makes the expensive one visible.
CHAIN_OK=true
if [ "$DRY" != 1 ] && [ -z "$ONLY" ] && command -v pg_ledger_verify >/dev/null 2>&1; then
  for _led in proofgate-claims proofgate-hypotheses; do
    _f="$(pg_git_dir)/$_led.jsonl"
    [ -f "$_f" ] || continue
    if ! _bad="$(pg_ledger_verify "$_f")"; then
      CHAIN_OK=false
      fail "ledger-chain: $_led.jsonl line $_bad does not follow the chain — a row was written or edited outside the tooling. Evidence that can be typed is not evidence." "ledger-chain"
    fi
  done
fi

# ── verdict ──────────────────────────────────────────────────────────────────
say "────────────────────────────────────────────────────────────"
if [ "$STRICT" = 1 ] && [ "$WARNS" -gt 0 ]; then
  say "❌ GATE FAILED (--strict): $WARNS warning(s) treated as failures."
  FAILS=$((FAILS + WARNS))
elif [ "$FAILS" -gt 0 ]; then
  say "❌ GATE FAILED: $FAILS item(s). The delivery is NOT done."
else
  say "✅ Mechanical gate passed ($WARNS warning(s) — justify each in your status)."
  say "   Now the JUDGMENT gate (SKILL.md, step 2) — with evidence."
fi
PASS_BOOL=$( [ "$FAILS" -gt 0 ] && echo false || echo true )

# ── machine-readable verdict + ledger (full runs only; not --only/--dry-run) ─
if [ "$DRY" != 1 ] && [ -z "$ONLY" ]; then
  GD="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
  SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  # ── verdict v2 ─────────────────────────────────────────────────────────────
  # ADDITIVE by contract. Four readers parse this file with grep/sed and none of
  # them can be upgraded in place: hooks/push-guard.sh, hooks/stop-guard.sh, the
  # pre-push hook install.sh WROTE INTO USERS' REPOS (it never updates itself), and
  # tests/run-tests.sh. They do:
  #     sed -n 's/.*"sha":"\([0-9a-f]\{7,40\}\)".*/\1/p'      ← GREEDY: last match wins
  #     grep -q '"pass":true'
  # So v2 keeps the v1 prefix byte-identical through "pass", stays on ONE line, and
  # contains exactly ONE "sha": and ONE "pass": in the whole document. Everything
  # nested says head_sha / base_sha / sha_ok instead. A test pins this.
  VERDICT="{\"schemaVersion\":2,\"sha\":\"$SHA\",\"generatedAt\":\"$TS\",\"flags\":{\"build\":$([ "$BUILD" = 1 ] && echo true || echo false),\"strict\":$([ "$STRICT" = 1 ] && echo true || echo false),\"smoke\":$([ "$SMOKE" = 1 ] && echo true || echo false)},\"checks\":[$CHECK_JSON],\"fails\":$FAILS,\"warns\":$WARNS,\"pass\":$PASS_BOOL"
  VERDICT="$VERDICT,\"impact\":{\"risk_class\":\"${RISK:-unknown}\",\"navigation_backend\":\"${NAV_BACKEND:-none}\",\"navigation_confidence\":\"${NAV_CONF:-none}\",\"skeptic_required\":${SKEPTIC_REQ:-false}}"
  VERDICT="$VERDICT,\"required_level\":\"${REQUIRED_LEVEL:-unknown}\",\"max_achievable_level\":\"${MAX_LEVEL:-unknown}\""
  VERDICT="$VERDICT,\"degradations\":[$(printf '%s' "${IMPACT_DEGR:-}" | awk '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1?",":""), $i}')]"
  PG_MODE=normal; [ -f "$(pg_git_dir)/proofgate-mode" ] && PG_MODE=prototype
  VERDICT="$VERDICT,\"mode\":\"$PG_MODE\""
  VERDICT="$VERDICT,\"achieved_level\":\"${ACHIEVED_LEVEL:-unknown}\",\"proof\":{\"status\":\"$PROOF_STATUS\",\"missing\":\"$(pg_json_escape "$PROOF_MISSING")\"},\"chain_ok\":$CHAIN_OK}"
  if [ -d "$GD" ]; then
    TMPV="$(mktemp "$GD/.proofgate-verdict.XXXXXX" 2>/dev/null || mktemp)"
    printf '%s\n' "$VERDICT" > "$TMPV" && mv "$TMPV" "$GD/proofgate-verdict.json"
    if [ "$FAILS" -gt 0 ] || [ "$WARNS" -gt 0 ]; then
      printf '{"sha":"%s","ts":"%s","fails":%d,"warns":%d,"fired":"%s"}\n' \
        "$SHA" "$TS" "$FAILS" "$WARNS" "$(printf '%s' "$FIRED" | sed 's/^ //')" >> "$GD/proofgate-ledger.jsonl" 2>/dev/null || true
    fi
  fi
  [ "$JSON" = 1 ] && printf '%s\n' "$VERDICT"
fi

# ── GitHub step summary (free when running in Actions) ───────────────────────
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$DRY" != 1 ]; then
  {
    echo "## ProofGate — $( [ "$FAILS" -gt 0 ] && echo '❌ FAILED' || echo '✅ passed' )"
    echo "\`$FAILS\` failure(s) · \`$WARNS\` warning(s)"
    echo '```'
    printf '%s' "$LINES"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [ -n "$REPORT" ]; then
  { echo "# ProofGate report — $(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo now)"; echo; echo '```'; printf '%s' "$LINES"; echo '```'; } > "$REPORT"
  [ "$JSON" = 1 ] || echo "report written: $REPORT"
fi

[ "$FAILS" -gt 0 ] && exit 1 || exit 0
