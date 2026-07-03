#!/usr/bin/env bash
# ProofGate — the MECHANICAL gate. The half of the checklist a machine checks
# better than judgment. Judgment lives in SKILL.md; guards live in guards.d/.
#
# Usage:
#   bash verify.sh                    # fast gate (no build)
#   bash verify.sh --build            # include the build (pre-release)
#   bash verify.sh --strict           # warnings become failures
#   bash verify.sh --dry-run          # show what would run, run nothing
#   bash verify.sh --base <ref>       # diff base (default: merge-base with origin default branch)
#   bash verify.sh --report <file>    # also write a markdown report
#
# Exit codes: 0 = gate passed (warnings allowed unless --strict) · 1 = gate FAILED.
#
# Optional config (repo root, all keys optional, requires jq):
#   proofgate.json
#   {
#     "commands": { "typecheck": "...", "test": "...", "build": "...", "lint": "..." },
#     "coupledFiles": [ { "a": "path/a", "b": "path/b", "reason": "why they move together" } ],
#     "piiTerms": "phone|cpf|ssn|medical",
#     "sourceGlobs": "src/|lib/|app/",
#     "envExample": ".env.example"
#   }
set -uo pipefail

# ── flags ────────────────────────────────────────────────────────────────────
BUILD=0 STRICT=0 DRY=0 BASE_REF="" REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD=1 ;;
    --strict) STRICT=1 ;;
    --dry-run) DRY=1 ;;
    --base) shift; BASE_REF="${1:-}" ;;
    --report) shift; REPORT="${1:-}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)"; exit 1 ;;
  esac
  shift
done

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
GUARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guards.d"

FAILS=0 WARNS=0 LINES=""
say()  { echo "$1"; LINES="${LINES}${1}"$'\n'; }
ok()   { say "✅ $1"; }
fail() { say "❌ $1"; FAILS=$((FAILS + 1)); }
warn() { say "⚠️  $1"; WARNS=$((WARNS + 1)); }

run_step() { # run_step <label> <command...>
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then say "▫️  would run [$label]: $*"; return 0; fi
  local log; log="$(mktemp)"
  if "$@" >"$log" 2>&1; then ok "$label"; else fail "$label BROKEN — last lines:"; tail -5 "$log" | sed 's/^/     /'; fi
  rm -f "$log"
}

say "── ProofGate · mechanical gate ─────────────────────────────"

# ── stack detection + configured commands ───────────────────────────────────
CFG="proofgate.json"
cfg() { # cfg <jq-path> — empty when absent
  [ -f "$CFG" ] && command -v jq >/dev/null 2>&1 && jq -r "$1 // empty" "$CFG" 2>/dev/null || true
}

PM=""
if   [ -f pnpm-lock.yaml ];      then PM="pnpm"
elif [ -f yarn.lock ];           then PM="yarn"
elif [ -f bun.lockb ] || [ -f bun.lock ]; then PM="bun"
elif [ -f package-lock.json ] || [ -f package.json ]; then PM="npm"
fi

has_script() { # npm-family script present?
  [ -n "$PM" ] && [ -f package.json ] && grep -q "\"$1\"[[:space:]]*:" package.json
}

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
      else warn "no typecheck detected (add commands.typecheck to proofgate.json)"; fi ;;
    test)
      if has_script test; then run_step "tests ($PM)" "$PM" test
      elif [ -f Cargo.toml ]; then run_step "tests (cargo)" cargo test --quiet
      elif [ -f go.mod ]; then run_step "tests (go)" go test ./...
      elif [ -f pyproject.toml ] && command -v pytest >/dev/null 2>&1; then run_step "tests (pytest)" pytest -q
      else warn "no test runner detected (add commands.test to proofgate.json)"; fi ;;
    build)
      if has_script build; then run_step "build ($PM)" "$PM" run build
      elif [ -f Cargo.toml ]; then run_step "build (cargo)" cargo build --quiet
      elif [ -f go.mod ]; then run_step "build (go)" go build ./...
      else warn "no build detected (add commands.build to proofgate.json)"; fi ;;
  esac
}

run_named typecheck
run_named test
if [ "$BUILD" = 1 ]; then run_named build; else warn "build NOT run (use --build before releasing)"; fi

# ── git: committed AND pushed — unpushed work is work that can vanish ───────
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  ok "working tree clean (everything committed)"
else
  fail "UNCOMMITTED changes present — commit+push before declaring done"
fi
if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ]; then
    ok "HEAD pushed (matches $(git rev-parse --abbrev-ref '@{u}'))"
  else
    fail "HEAD NOT pushed (local differs from upstream)"
  fi
else
  warn "branch has no upstream — push with: git push -u origin <branch>"
fi

# ── diff-based guards (guards.d/*.sh, alphabetical) ──────────────────────────
if [ -z "$BASE_REF" ]; then
  DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -z "$DEFAULT_BRANCH" ] && for b in main master; do git rev-parse "origin/$b" >/dev/null 2>&1 && { DEFAULT_BRANCH="$b"; break; }; done
  [ -n "$DEFAULT_BRANCH" ] && BASE_REF="$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || true)"
fi

if [ -n "$BASE_REF" ] && [ "$BASE_REF" != "$(git rev-parse HEAD)" ]; then
  export PROOFGATE_BASE="$BASE_REF" PROOFGATE_CFG="$CFG" PROOFGATE_STRICT="$STRICT"
  if [ -d "$GUARDS_DIR" ]; then
    for guard in "$GUARDS_DIR"/*.sh; do
      [ -f "$guard" ] || continue
      if [ "$DRY" = 1 ]; then say "▫️  would run guard: $(basename "$guard")"; continue; fi
      OUT="$(bash "$guard" 2>&1)"; CODE=$?
      [ -n "$OUT" ] && while IFS= read -r line; do say "$line"; done <<< "$OUT"
      case $CODE in
        0) : ;;                 # guard reported its own ✅/silence
        1) FAILS=$((FAILS+1)) ;;
        2) WARNS=$((WARNS+1)) ;;
      esac
    done
  fi
else
  warn "empty diff against the default branch (nothing to deliver? or fetch origin first)"
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

if [ -n "$REPORT" ]; then
  { echo "# ProofGate report — $(date -u +%Y-%m-%dT%H:%MZ)"; echo; echo '```'; printf '%s' "$LINES"; echo '```'; } > "$REPORT"
  echo "report written: $REPORT"
fi

[ "$FAILS" -gt 0 ] && exit 1 || exit 0
