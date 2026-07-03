#!/usr/bin/env bash
# ProofGate's own acceptance tests — the gate gates itself.
# Three harnesses:
#   caso()        — plant a sin in a synthetic repo, run ONE guard, assert its exit.
#   caso_verify() — run the WHOLE engine against a synthetic repo (with a bare
#                   remote so the pushed-state check is real), assert exit + custom.
#   caso_hook()   — feed a synthetic event on stdin to a hook, assert its exit/output.
# Positive AND negative paths for everything: a guard that never fires is as broken
# as one that always does.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
GUARDS="$ROOT/skills/proofgate/scripts/guards.d"
VERIFY="$ROOT/skills/proofgate/scripts/verify.sh"
LIB="$ROOT/skills/proofgate/scripts/lib.sh"
export PROOFGATE_LIB="$LIB"
PASS=0 FAIL=0

# A JSON validator that degrades gracefully (jq → python3 → node → SKIP).
json_ok() { # json_ok <file>
  if command -v jq >/dev/null 2>&1; then jq -e . "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import sys,json;json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  elif command -v node >/dev/null 2>&1; then node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$1" >/dev/null 2>&1
  else return 2; fi
}

# ── guard harness ─────────────────────────────────────────────────────────────
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
  if [ "$code" = "$esperado" ]; then echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado, got $code"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmp"
}

# ── engine harness ────────────────────────────────────────────────────────────
caso_verify() { # caso_verify <name> <expected-exit> <setup-fn> <assert-fn> [verify-args...]
  local nome="$1" esperado="$2" setup="$3" assert="$4"; shift 4
  local tmp remote; tmp="$(mktemp -d)"; remote="$(mktemp -d)"
  ( cd "$remote" && git init -q --bare ) >/dev/null 2>&1
  (
    cd "$tmp"
    git init -q -b main && git config user.email t@t && git config user.name t
    printf '{"commands":{"typecheck":"true","test":"true","build":"true","lint":"true"}}\n' > proofgate.json
    git add -A && git commit -qm base
    git remote add origin "$remote" && git push -qu origin main
    git checkout -q -b feature
    "$setup"
    git add -A && git commit -qm change
  ) >/dev/null 2>&1
  local code=0
  ( cd "$tmp" && bash "$VERIFY" "$@" ) >/tmp/pg-cv.out 2>&1 || code=$?
  local ok=1
  [ "$code" = "$esperado" ] || ok=0
  if [ -n "$assert" ]; then ( cd "$tmp" && "$assert" ) || ok=0; fi
  if [ "$ok" = 1 ]; then echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado, got $code (assert=$assert)"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmp" "$remote"
}

# ── hook harness ──────────────────────────────────────────────────────────────
caso_hook() { # caso_hook <name> <hook> <expected-exit> <stdin-json> <setup-fn> [expect-substr]
  local nome="$1" hook="$2" esperado="$3" input="$4" setup="$5" substr="${6:-}"
  local tmp; tmp="$(mktemp -d)"
  (
    cd "$tmp"
    git init -q -b main && git config user.email t@t && git config user.name t
    "$setup"           # opt-in setups create proofgate.json / .proofgate themselves
    git add -A && git commit -qm base
  ) >/dev/null 2>&1
  local code=0 out
  out="$(cd "$tmp" && printf '%s' "$input" | bash "$ROOT/hooks/$hook" 2>/dev/null)" || code=$?
  local ok=1
  [ "$code" = "$esperado" ] || ok=0
  [ -n "$substr" ] && { printf '%s' "$out" | grep -q "$substr" || ok=0; }
  if [ "$ok" = 1 ]; then echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado, got $code out=[$out]"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmp"
}

echo "══ guards ═══════════════════════════════════════════════════"
# ── 10-secrets ────────────────────────────────────────────────────────────────
plant_token()  { echo 'const k = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";' > leak.ts; }
plant_pem()    { printf -- '-----BEGIN RSA PRIVATE KEY-----\nx\n' > key.pem; }
plant_generic(){ echo 'const client_secret = "abcdef0123456789ABCDEFXYZ";' > cfg.ts; }
plant_ph()     { echo 'const token = "your_token_here_example_val";' > cfg.ts; }
plant_clean()  { echo 'export const soma = (a, b) => a + b;' > ok.ts; }
caso "secrets: GitHub token → FAIL"              1 10-secrets.sh plant_token
caso "secrets: private key → FAIL"               1 10-secrets.sh plant_pem
caso "secrets: generic assignment → WARN"        2 10-secrets.sh plant_generic
caso "secrets: placeholder value → pass"         0 10-secrets.sh plant_ph
caso "secrets: clean diff → pass"                0 10-secrets.sh plant_clean

# ── 12-merge-markers ──────────────────────────────────────────────────────────
plant_merge()  { printf 'ok\n%s%s HEAD\n' '<<<' '<<<<' > a.ts; }   # split so tests/ isn't a sin
plant_eq()     { printf '# Title\n%s\n' '=======' > README2.md; }  # bare ==== must NOT fire
caso "merge-markers: conflict marker → FAIL"     1 12-merge-markers.sh plant_merge
caso "merge-markers: markdown ==== → pass"       0 12-merge-markers.sh plant_eq

# ── 15-tls-off ────────────────────────────────────────────────────────────────
plant_tls()    { echo 'const o = { rejectUnauthorized: false };' > net.ts; }
plant_curlk()  { echo 'curl -k https://self-signed.local' > deploy.sh; }
caso "tls-off: rejectUnauthorized:false → FAIL"  1 15-tls-off.sh plant_tls
caso "tls-off: curl -k → WARN"                   2 15-tls-off.sh plant_curlk
caso "tls-off: clean → pass"                      0 15-tls-off.sh plant_clean

# ── 20-pii-logging ────────────────────────────────────────────────────────────
plant_pii()    { echo 'console.log("user phone:", user.phone);' > log.ts; }
plant_logok()  { echo 'console.log("cache warmed in", ms);' > log.ts; }
caso "pii-logging: phone into log → WARN"        2 20-pii-logging.sh plant_pii
caso "pii-logging: benign log → pass"            0 20-pii-logging.sh plant_logok

# ── 25-silent-catch ───────────────────────────────────────────────────────────
plant_catch()  { echo 'try { pay() } catch (e) {}' > a.ts; }
plant_okcatch(){ echo 'try { pay() } catch (e) { log(e) }' > a.ts; }
caso "silent-catch: empty catch → WARN"          2 25-silent-catch.sh plant_catch
caso "silent-catch: handled catch → pass"        0 25-silent-catch.sh plant_okcatch

# ── 30-untested-changes ───────────────────────────────────────────────────────
plant_src()    { mkdir -p src && echo "export const x = 1;" > src/a.ts; }
plant_both()   { mkdir -p src && echo "export const x = 1;" > src/a.ts && echo "test" > src/a.test.ts; }
caso "untested: src without tests → WARN"        2 30-untested-changes.sh plant_src
caso "untested: src + test together → pass"      0 30-untested-changes.sh plant_both

# ── 35-dependency-change ──────────────────────────────────────────────────────
plant_dep()    { printf '{"dependencies":{"left-pad":"^1.0.0"}}\n' > package.json; }
plant_deplock(){ printf '{"dependencies":{"left-pad":"^1.0.0"}}\n' > package.json; echo "lockfileVersion: 9" > pnpm-lock.yaml; }
caso "dependency: manifest w/o lockfile → WARN"  2 35-dependency-change.sh plant_dep
caso "dependency: manifest + lockfile → pass"    0 35-dependency-change.sh plant_deplock

# ── 40-env-drift ──────────────────────────────────────────────────────────────
plant_env()    { echo "OLD_VAR=1" > .env.example; echo 'const u = process.env.BRAND_NEW_VAR;' > cfg.ts; }
plant_envgo()  { echo "OLD_VAR=1" > .env.example; echo 'v := os.Getenv("BRAND_NEW_VAR")' > cfg.go; }
plant_envok()  { echo "GOOD_VAR=1" > .env.example; echo 'const u = process.env.GOOD_VAR;' > cfg.ts; }
caso "env-drift: undeclared var (node) → WARN"   2 40-env-drift.sh plant_env
caso "env-drift: undeclared var (go) → WARN"     2 40-env-drift.sh plant_envgo
caso "env-drift: declared var → pass"            0 40-env-drift.sh plant_envok

# ── 50-coupled-files ──────────────────────────────────────────────────────────
plant_pair()   { printf '{"coupledFiles":[{"a":"a.txt","b":"b.txt","reason":"t"}]}\n' > proofgate.json; echo x > a.txt; }
plant_pairok() { printf '{"coupledFiles":[{"a":"a.txt","b":"b.txt","reason":"t"}]}\n' > proofgate.json; echo x > a.txt; echo y > b.txt; }
caso "coupled: one side drifted → WARN"          2 50-coupled-files.sh plant_pair
caso "coupled: pair moved together → pass"       0 50-coupled-files.sh plant_pairok

# ── 55-skipped-tests ──────────────────────────────────────────────────────────
plant_skip()   { echo 'it.skip("x", () => {});' > a.test.ts; }
plant_noskip() { echo 'it("x", () => {});' > a.test.ts; }
caso "skipped-tests: .skip added → WARN"         2 55-skipped-tests.sh plant_skip
caso "skipped-tests: normal test → pass"         0 55-skipped-tests.sh plant_noskip

# ── 58-frozen-clock ───────────────────────────────────────────────────────────
plant_clock()  { echo 'const t = Date.now();' > a.test.ts; }
plant_clockok(){ echo 'const t = Date.now();' > a.ts; }
caso "frozen-clock: now() in test → WARN"        2 58-frozen-clock.sh plant_clock
caso "frozen-clock: now() in source → pass"      0 58-frozen-clock.sh plant_clockok

# ── 65-type-suppressions ──────────────────────────────────────────────────────
plant_tsignore(){ echo '// @ts-ignore' > a.ts; }
plant_expect() { echo '// @ts-expect-error' > a.ts; }
caso "type-suppressions: @ts-ignore → WARN"      2 65-type-suppressions.sh plant_tsignore
caso "type-suppressions: @ts-expect-error → pass" 0 65-type-suppressions.sh plant_expect

# ── 60-large-files ────────────────────────────────────────────────────────────
plant_big()    { head -c 3145728 /dev/zero > video.bin; }
caso "large-files: 3MB blob → WARN"              2 60-large-files.sh plant_big
caso "large-files: small file → pass"            0 60-large-files.sh plant_clean

# ── 70-debug-leftovers ────────────────────────────────────────────────────────
plant_only()   { echo 'it.only("works", () => {});' > a.test.ts; }
plant_debug()  { echo 'debugger; // wip' > a.ts; }
caso "debug: it.only → FAIL"                     1 70-debug-leftovers.sh plant_only
caso "debug: debugger → WARN"                    2 70-debug-leftovers.sh plant_debug
caso "debug: clean diff → pass"                  0 70-debug-leftovers.sh plant_clean

# ── 75-machine-paths ──────────────────────────────────────────────────────────
plant_home()   { echo 'const p = "/home/alice/proj/x";' > a.ts; }
plant_ctr()    { echo 'const p = "/home/node/app";' > a.ts; }
caso "machine-paths: /home/<user> → WARN"        2 75-machine-paths.sh plant_home
caso "machine-paths: container path → pass"      0 75-machine-paths.sh plant_ctr

# ── 85-float-money ────────────────────────────────────────────────────────────
plant_money()  { echo 'const total = parseFloat(x);' > a.ts; }
plant_notmoney(){ echo 'const label = parseFloat(x);' > a.ts; }
caso "float-money: parseFloat(total) → WARN"     2 85-float-money.sh plant_money
caso "float-money: non-money float → pass"       0 85-float-money.sh plant_notmoney

# ── 90-sql-concat ─────────────────────────────────────────────────────────────
plant_sql()    { echo 'db.query("SELECT id FROM users WHERE x = " + y);' > a.ts; }
plant_sqlok()  { echo 'db.query(sql`SELECT id FROM users`);' > a.ts; }
caso "sql-concat: concatenated SQL → WARN"       2 90-sql-concat.sh plant_sql
caso "sql-concat: tagged template → pass"        0 90-sql-concat.sh plant_sqlok

echo "══ engine ══════════════════════════════════════════════════"
a_verdict_valid() { local gd; gd="$(git rev-parse --git-dir)"; [ -f "$gd/proofgate-verdict.json" ] && json_ok "$gd/proofgate-verdict.json"; }
a_sha_matches()   { local gd sha; gd="$(git rev-parse --git-dir)"; sha="$(sed -n 's/.*"sha":"\([0-9a-f]*\)".*/\1/p' "$gd/proofgate-verdict.json" | head -1)"; [ "$sha" = "$(git rev-parse HEAD)" ]; }
a_pass_true()     { grep -q '"pass":true' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
a_pass_false()    { grep -q '"pass":false' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
a_no_verdict()    { [ ! -f "$(git rev-parse --git-dir)/proofgate-verdict.json" ]; }
a_lint_ran()      { [ -f "$(git rev-parse --git-dir)/lint-ran" ]; }
a_true()          { return 0; }
setup_clean()     { mkdir -p src; echo "export const x = 1;" > src/a.ts; echo 'it("w",()=>{})' > src/a.test.ts; }
setup_failtest()  { printf '{"commands":{"typecheck":"true","test":"false","build":"true","lint":"true"}}\n' > proofgate.json; echo x > src_a.ts; }
setup_lintstub()  { printf '{"commands":{"typecheck":"true","test":"true","lint":"touch .git/lint-ran"}}\n' > proofgate.json; echo x > a.ts; }
setup_warnsin()   { echo 'debugger;' > a.ts; }   # 70-debug WARN
setup_failsin()   { printf 'ok\n%s%s HEAD\n' '<<<' '<<<<' > a.ts; }  # merge-marker FAIL
setup_skipcfg()   { printf '{"commands":{"typecheck":"true","test":"true"},"skip":["debug-leftovers"]}\n' > proofgate.json; echo 'debugger;' > a.ts; }
setup_sevcfg()    { printf '{"commands":{"typecheck":"true","test":"true"},"severity":{"debug-leftovers":"warn"}}\n' > proofgate.json; echo 'it.only("x",()=>{})' > a.test.ts; }

caso_verify "engine: green repo → exit 0 + valid verdict" 0 setup_clean a_verdict_valid
caso_verify "engine: verdict sha == HEAD"                 0 setup_clean a_sha_matches
caso_verify "engine: green repo → pass:true"              0 setup_clean a_pass_true
caso_verify "engine: failing test → exit 1 + pass:false"  1 setup_failtest a_pass_false
caso_verify "engine: --strict passes w/o --build (note trap)" 0 setup_clean a_true --strict
caso_verify "engine: --strict promotes a warn → exit 1"   1 setup_warnsin a_true --strict
caso_verify "engine: lint command actually runs"          0 setup_lintstub a_lint_ran
caso_verify "engine: planted FAIL sin → exit 1"           1 setup_failsin a_true
caso_verify "engine: skip config silences a guard"        0 setup_skipcfg a_true
caso_verify "engine: severity warn demotes a FAIL → exit 0" 0 setup_sevcfg a_true
caso_verify "engine: --only writes NO verdict"            0 setup_warnsin a_no_verdict --only debug-leftovers
caso_verify "engine: --dry-run writes NO verdict"         0 setup_clean a_no_verdict --dry-run

echo "══ hooks ═══════════════════════════════════════════════════"
optin()   { printf '{"pushGuard":true}\n' > proofgate.json; mkdir -p .proofgate && cp "$LIB" .proofgate/lib.sh; }
optin_stop(){ printf '{"pushGuard":true,"stopGuard":true}\n' > proofgate.json; mkdir -p .proofgate && cp "$LIB" .proofgate/lib.sh; }
nooptin() { echo "x" > x.txt; }   # deliberately no proofgate.json / .proofgate → not adopted
ev() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# push-guard: absent verdict → block
caso_hook "push-guard: no verdict → block"  push-guard.sh 2 "$(ev 'git push origin main')" optin
# push-guard: non-push → allow
caso_hook "push-guard: non-push → allow"    push-guard.sh 0 "$(ev 'git status')" optin
# push-guard: --no-verify bypass → block
caso_hook "push-guard: --no-verify → block" push-guard.sh 2 "$(ev 'git push --no-verify')" optin
# push-guard: no opt-in → allow
caso_hook "push-guard: no opt-in → allow"   push-guard.sh 0 "$(ev 'git push')" nooptin
# push-guard: malformed stdin → fail-open allow
caso_hook "push-guard: malformed → allow"   push-guard.sh 0 'not json but has push word' optin
# stop-guard: default off → allow (no block output)
caso_hook "stop-guard: default off → allow" stop-guard.sh 0 '{}' optin
# stop-guard: opt-in + no verdict → block JSON
caso_hook "stop-guard: opt-in stale → block" stop-guard.sh 0 '{}' optin_stop '"decision":"block"'
# stop-guard: loop guard → allow
caso_hook "stop-guard: stop_hook_active → allow" stop-guard.sh 0 '{"stop_hook_active":true}' optin_stop

# push-guard with a FRESH verdict → allow (needs the verdict written for real HEAD)
tmpf="$(mktemp -d)"
( cd "$tmpf"; git init -q -b main; git config user.email t@t; git config user.name t
  printf '{"pushGuard":true}\n' > proofgate.json; mkdir -p .proofgate; cp "$LIB" .proofgate/lib.sh
  git add -A; git commit -qm base
  printf '{"sha":"%s","pass":true}\n' "$(git rev-parse HEAD)" > .git/proofgate-verdict.json ) >/dev/null 2>&1
code=0; ( cd "$tmpf"; printf '%s' "$(ev 'git push origin main')" | bash "$ROOT/hooks/push-guard.sh" ) >/dev/null 2>&1 || code=$?
if [ "$code" = 0 ]; then echo "PASS  push-guard: fresh+pass → allow (exit 0)"; PASS=$((PASS+1)); else echo "FAIL  push-guard: fresh+pass → expected 0 got $code"; FAIL=$((FAIL+1)); fi
rm -rf "$tmpf"

echo "═════════════════════════════════════════════════════════════"
echo "$PASS passed · $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
