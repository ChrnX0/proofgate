#!/usr/bin/env bash
# ProofGate's own acceptance tests — the gate gates itself.
# Each case builds a tiny synthetic git repo, plants a known sin (or a clean
# diff), runs ONE guard, and asserts the exact exit code: positive AND negative
# paths, because a guard that never fires is as broken as one that always does.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
GUARDS="$(pwd)/skills/proofgate/scripts/guards.d"
PASS=0 FAIL=0

caso() { # caso <name> <expected-exit> <guard-file> <setup-fn>
  local nome="$1" esperado="$2" guard="$3" setup="$4"
  local tmp; tmp="$(mktemp -d)"
  (
    cd "$tmp"
    git init -q && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m base
    "$setup"
    git add -A >/dev/null 2>&1 && git commit -qm change --allow-empty
  ) >/dev/null 2>&1
  local code=0
  (cd "$tmp" && PROOFGATE_BASE="$(git rev-parse HEAD~1)" PROOFGATE_CFG="proofgate.json" bash "$GUARDS/$guard") >/dev/null 2>&1 || code=$?
  if [ "$code" = "$esperado" ]; then
    echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else
    echo "FAIL  $nome — expected exit $esperado, got $code"; FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmp"
}

# ── 10-secrets ────────────────────────────────────────────────────────────────
plant_token()  { echo 'const k = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";' > leak.ts; }
plant_pem()    { printf -- '-----BEGIN RSA PRIVATE KEY-----\nx\n' > key.pem; }
plant_clean()  { echo 'export const soma = (a, b) => a + b;' > ok.ts; }
caso "secrets: GitHub token added → FAIL"        1 10-secrets.sh plant_token
caso "secrets: private key added → FAIL"         1 10-secrets.sh plant_pem
caso "secrets: clean diff → pass"                0 10-secrets.sh plant_clean

# ── 20-pii-logging ────────────────────────────────────────────────────────────
plant_pii()    { echo 'console.log("user phone:", user.phone);' > log.ts; }
plant_logok()  { echo 'console.log("cache warmed in", ms);' > log.ts; }
caso "pii-logging: phone into console.log → WARN" 2 20-pii-logging.sh plant_pii
caso "pii-logging: benign log → pass"             0 20-pii-logging.sh plant_logok

# ── 30-untested-changes ───────────────────────────────────────────────────────
plant_src()    { mkdir -p src && echo "export const x = 1;" > src/a.ts; }
plant_both()   { mkdir -p src && echo "export const x = 1;" > src/a.ts && echo "test" > src/a.test.ts; }
caso "untested: src without tests → WARN"        2 30-untested-changes.sh plant_src
caso "untested: src + test together → pass"      0 30-untested-changes.sh plant_both

# ── 40-env-drift ──────────────────────────────────────────────────────────────
plant_env()    { echo "OLD_VAR=1" > .env.example; echo 'const u = process.env.BRAND_NEW_VAR;' > cfg.ts; }
plant_envok()  { echo "GOOD_VAR=1" > .env.example; echo 'const u = process.env.GOOD_VAR;' > cfg.ts; }
caso "env-drift: undeclared var read → WARN"     2 40-env-drift.sh plant_env
caso "env-drift: declared var → pass"            0 40-env-drift.sh plant_envok

# ── 50-coupled-files ──────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  plant_pair()  { printf '{"coupledFiles":[{"a":"a.txt","b":"b.txt","reason":"t"}]}' > proofgate.json; echo x > a.txt; }
  plant_pairok(){ printf '{"coupledFiles":[{"a":"a.txt","b":"b.txt","reason":"t"}]}' > proofgate.json; echo x > a.txt; echo y > b.txt; }
  caso "coupled: one side drifted → WARN"        2 50-coupled-files.sh plant_pair
  caso "coupled: pair moved together → pass"     0 50-coupled-files.sh plant_pairok
else
  echo "SKIP  coupled-files (no jq on this machine)"
fi

# ── 60-large-files ────────────────────────────────────────────────────────────
plant_big()    { head -c 3145728 /dev/zero > video.bin; }
caso "large-files: 3MB blob → WARN"              2 60-large-files.sh plant_big
caso "large-files: small file → pass"            0 60-large-files.sh plant_clean

# ── 70-debug-leftovers ────────────────────────────────────────────────────────
plant_only()   { echo 'it.only("works", () => {});' > a.test.ts; }
plant_debug()  { echo 'debugger; // wip' > a.ts; }
caso "debug: it.only added → FAIL"               1 70-debug-leftovers.sh plant_only
caso "debug: debugger added → WARN"              2 70-debug-leftovers.sh plant_debug
caso "debug: clean diff → pass"                  0 70-debug-leftovers.sh plant_clean

echo "─────────────────────────────────────"
echo "$PASS passed · $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
