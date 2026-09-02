#!/usr/bin/env bash
# ProofGate's own acceptance tests — the gate gates itself.
# Three harnesses:
#   caso()        — plant a sin in a synthetic repo, run ONE guard, assert its exit.
#   caso_verify() — run the WHOLE engine against a synthetic repo (with a bare
#                   remote so the pushed-state check is real), assert exit + custom.
#   caso_hook()   — feed a synthetic event on stdin to a hook, assert its exit/output.
#   caso_tool()   — run ANY script in scripts/ against a synthetic repo, assert
#                   exit + a custom assertion (impact.sh, claim.sh, ... ).
# Positive AND negative paths for everything: a guard that never fires is as broken
# as one that always does.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
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
    cd "$tmp" || exit 1
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
    cd "$tmp" || exit 1
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
    cd "$tmp" || exit 1
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

# ── generic tool harness ──────────────────────────────────────────────────────
# caso_verify hard-codes verify.sh. Everything from 2.7 on ships its own script,
# and each one needs the same fixture: a real repo, a real remote, a real base.
caso_tool() { # caso_tool <name> <expected-exit> <setup-fn> <assert-fn> -- <script> [args...]
  local nome="$1" esperado="$2" setup="$3" assert="$4"; shift 4
  [ "${1:-}" = "--" ] && shift
  local script="$1"; shift
  local tmp remote; tmp="$(mktemp -d)"; remote="$(mktemp -d)"
  ( cd "$remote" && git init -q --bare ) >/dev/null 2>&1
  (
    cd "$tmp" || exit 1
    git init -q -b main && git config user.email t@t && git config user.name t
    printf '{"commands":{"typecheck":"true","test":"true","build":"true","lint":"true"}}\n' > proofgate.json
    git add -A && git commit -qm base
    git remote add origin "$remote" && git push -qu origin main
    git checkout -q -b feature
    "$setup"
    git add -A && git commit -qm change
  ) >/dev/null 2>&1
  local code=0
  # </dev/null matters: a tool that reads stdin by accident must fail the test,
  # not hang the suite. (pg_sha1 with a missing path did exactly that once.)
  ( cd "$tmp" && PROOFGATE_LIB="$LIB" bash "$script" "$@" </dev/null ) >/tmp/pg-tool.out 2>&1 || code=$?
  local ok=1
  [ "$code" = "$esperado" ] || ok=0
  if [ -n "$assert" ]; then ( cd "$tmp" && "$assert" ) || ok=0; fi
  if [ "$ok" = 1 ]; then echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado, got $code (assert=$assert)"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmp" "$remote"
}

echo "══ guards ═══════════════════════════════════════════════════"
# ── 10-secrets ────────────────────────────────────────────────────────────────
plant_token()  { echo 'const k = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";' > leak.ts; }
plant_pem()    { printf -- '-----BEGIN RSA PRIVATE KEY-----\nx\n' > key.pem; }
plant_generic(){ echo 'const client_secret = "abcdef0123456789ABCDEFXYZ";' > cfg.ts; }
plant_ph()     { echo 'const token = "your_token_here_example_val";' > cfg.ts; }
plant_clean()  { echo 'export const soma = (a, b) => a + b;' > ok.ts; }
# The ouroboros, found by the self-gate on its own 2.7.0 diff: suppressing a finding
# means writing the offending pattern into .proofgateignore (to say WHICH finding),
# which then trips the same guard. ProofGate's own control file is never scanned.
plant_ignorefile() { echo 'export const ok = 1;' > ok.ts
                     printf '# suppressing rejectUnauthorized: false in a vendored fixture\ntls-off:x.ts:abc123def456\n' > .proofgateignore; }
caso "secrets: GitHub token → FAIL"              1 10-secrets.sh plant_token
caso "secrets: private key → FAIL"               1 10-secrets.sh plant_pem
caso "secrets: generic assignment → WARN"        2 10-secrets.sh plant_generic
caso "secrets: placeholder value → pass"         0 10-secrets.sh plant_ph
caso "secrets: clean diff → pass"                0 10-secrets.sh plant_clean
caso "tls-off: .proofgateignore naming the pattern → pass" 0 15-tls-off.sh plant_ignorefile

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

# ── 95-schema-constraint-no-migration ─────────────────────────────────────────
# The sin: tightening a column inside `create table if not exists` — a no-op on any
# database that already has the table, so the constraint never reaches production.
plant_ddl()    { printf 'create table if not exists users (\n  id uuid primary key,\n  sex text check (sex in (\x27M\x27, \x27F\x27))\n);\n' > schema.sql; }
# Same constraint, but the delivery also ships the ALTER that reaches a live database.
plant_ddlok()  { plant_ddl; printf 'alter table users add constraint users_sex_valid check (sex in (\x27M\x27, \x27F\x27));\n' >> schema.sql; }
# A brand-new table carries its own constraints — nothing to migrate.
plant_ddlnew() { printf 'create table teams (\n  id uuid primary key,\n  name text not null\n);\n' > schema.sql; }
caso "schema-constraint: check in if-not-exists → WARN"  2 95-schema-constraint-no-migration.sh plant_ddl
caso "schema-constraint: shipped with ALTER → pass"      0 95-schema-constraint-no-migration.sh plant_ddlok
caso "schema-constraint: brand-new table → pass"         0 95-schema-constraint-no-migration.sh plant_ddlnew

# ── 96-version-bump-no-release ────────────────────────────────────────────────
# The sin: a manifest version goes up and nothing in the delivery cuts a release, so
# "merged" gets reported as "shipped" while the shop window still shows the old number.
plant_bump()     { printf '{\n  "name": "x",\n  "version": "2.3.0"\n}\n' > package.json; }
# Release automation owns the cutting — nothing to ask.
plant_bumpauto() { plant_bump; mkdir -p .changeset; printf 'x\n' > .changeset/config.json; }
# A tag-triggered release workflow ships with the bump.
plant_bumpci()   { plant_bump; mkdir -p .github/workflows
                   printf 'on:\n  push:\n    tags: ["v*"]\njobs:\n  release:\n    steps:\n      - uses: softprops/action-gh-release@v2\n' > .github/workflows/release.yml; }
# A manifest touched for something OTHER than the version must stay quiet.
plant_nobump()   { printf '{\n  "name": "x",\n  "version": "2.3.0",\n  "license": "Apache-2.0"\n}\n' > package.json; }
caso "version-release: bump with no release → WARN"       2 96-version-bump-no-release.sh plant_bump
caso "version-release: bump + release automation → pass"  0 96-version-bump-no-release.sh plant_bumpauto
caso "version-release: bump + tag-triggered CI → pass"    0 96-version-bump-no-release.sh plant_bumpci
# O caso do FALSO POSITIVO, que é a regra de desenho da ferramenta: manifesto mexido
# por outro motivo (dependência, licença) não pode alarmar em toda entrega. O setup
# commita a base COM a versão e depois muda só a licença, então a linha da versão não
# aparece entre as adicionadas.
plant_nobump()   { printf '{\n  "name": "x",\n  "version": "2.3.0",\n  "license": "MIT"\n}\n' > package.json
                   git add -A >/dev/null 2>&1; git commit -qm comversao >/dev/null 2>&1
                   printf '{\n  "name": "x",\n  "version": "2.3.0",\n  "license": "Apache-2.0"\n}\n' > package.json; }
caso "version-release: manifest edit, no bump → pass"     0 96-version-bump-no-release.sh plant_nobump

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

# --only has to reach a PROJECT guard (config.guardsDirs), not just the engine's
# own guards.d. Before 2.6.0 it searched one directory, so the guard a maintainer
# had just written was the one guard --only could not run.
setup_projguard() {
  printf '{"commands":{"typecheck":"true","test":"true"},"guardsDirs":["mine"]}\n' > proofgate.json
  mkdir -p mine
  printf '#!/usr/bin/env bash\necho "project guard ran"\nexit 0\n' > mine/90-project-only.sh
  echo 'x' > a.ts
}
a_projguard_ran()  { grep -q "project guard ran" /tmp/pg-cv.out; }
a_names_both_dirs() { grep -q "guards.d" /tmp/pg-cv.out && grep -q "mine" /tmp/pg-cv.out; }

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
caso_verify "engine: --only reaches a guardsDirs guard"   0 setup_projguard a_projguard_ran --only project-only
caso_verify "engine: --only on an unknown name names every dir it searched" 1 setup_projguard a_names_both_dirs --only nope
caso_verify "engine: --dry-run writes NO verdict"         0 setup_clean a_no_verdict --dry-run

# sourceless-diff — the blind-gate trap. When a delivery is fast-forwarded onto the
# default branch and the gate runs AFTER, the base moves with the work: the guards then
# inspect a docs-only diff and every one reports "nothing touched", which reads as
# approval. They cannot detect it from the inside, so the engine warns.
setup_docsonly()   { echo "# notes" > NOTES.md; }
a_sourceless()     { grep -q "sourceless-diff" /tmp/pg-cv.out; }
a_not_sourceless() { ! grep -q "sourceless-diff" /tmp/pg-cv.out; }
caso_verify "engine: docs-only diff → warns the guards were blind" 0 setup_docsonly a_sourceless
caso_verify "engine: diff with source → no blind-gate warning"     0 setup_clean a_not_sourceless

# ── verdict v2: the contract four un-upgradable readers depend on ────────────
a_v2()         { grep -q '"schemaVersion":2' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
a_one_sha()    { local v; v="$(git rev-parse --git-dir)/proofgate-verdict.json"
                 [ "$(grep -o '"sha":"' "$v" | wc -l | tr -d ' ')" = 1 ] &&
                 [ "$(grep -o '"pass":' "$v" | wc -l | tr -d ' ')" = 1 ] &&
                 [ "$(wc -l < "$v" | tr -d ' ')" = 1 ]; }
a_has_impact() { grep -q '"impact":{"risk_class":"L' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
a_required()   { grep -q '"required_level":"E' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
caso_verify "engine: verdict is schemaVersion 2"                  0 setup_clean a_v2
caso_verify "engine: verdict has exactly one sha + one pass, one line" 0 setup_clean a_one_sha
caso_verify "engine: verdict carries the impact risk class"       0 setup_clean a_has_impact
caso_verify "engine: verdict carries required_level"              0 setup_clean a_required
a_impact_line() { grep -q "impact: L" /tmp/pg-cv.out; }
caso_verify "engine: prints the blast-radius line"                0 setup_clean a_impact_line
a_no_impact_line() { ! grep -q "impact: L" /tmp/pg-cv.out; }
caso_verify "engine: --no-impact skips it"                        0 setup_clean a_no_impact_line --no-impact

echo "══ impact: the blast radius ════════════════════════════════"
IMPACT="$ROOT/skills/proofgate/scripts/impact.sh"
ij()  { cat "$(git rev-parse --git-dir)/proofgate-impact.json"; }
ihas() { local j; j="$(ij)"; printf '%s' "$j" | grep -q "$1"; }
setup_docs()     { echo "# notes" > NOTES.md; }
setup_caller()   { mkdir -p src
                   printf 'export function parsePrice(r){ return Number(r) }\n' > src/price.ts
                   printf 'import { parsePrice } from "./price";\nexport const t = (x) => parsePrice(x);\n' > src/cart.ts
                   printf 'import { parsePrice } from "./price";\nit("p", () => parsePrice("1"));\n' > src/price.test.ts
                   git add -A >/dev/null 2>&1; git commit -qm seed >/dev/null 2>&1
                   printf 'export function parsePrice(r){ const c = Math.round(Number(r)*100); return c/100 }\n' > src/price.ts; }
setup_auth()     { mkdir -p src/auth; echo 'export const login = (u) => u;' > src/auth/login.ts; }
setup_termstest() { mkdir -p tests; printf 'const bearer="x";\nconst isAdmin=true;\nconst refund=1;\n' > tests/a.test.ts; }
setup_termssrc()  { mkdir -p src; printf 'const bearer="x";\nconst isAdmin=true;\n' > src/a.ts; }
setup_e2e()      { mkdir -p src; echo 'export const x=1;' > src/a.ts
                   printf '{"commands":{"typecheck":"true","test":"true","e2e":"npm run e2e"}}\n' > proofgate.json; }
# Anti-slicing: the sin is committed FIRST, then an unrelated commit lands on top.
# A gate that judged only the tip would see the second commit and call it L1.
setup_sliced()   { mkdir -p src/payment; echo 'export const charge = (c) => c;' > src/payment/charge.ts
                   git add -A >/dev/null 2>&1; git commit -qm "the real change" >/dev/null 2>&1
                   echo "# docs" > NOTE.md; }

a_L1()        { ihas '"risk_class":"L1"' && ihas '"required_level":"E1"'; }
a_L2()        { ihas '"risk_class":"L2"' && ihas '"required_level":"E3"'; }
a_L3()        { ihas '"risk_class":"L3"' && ihas '"skeptic_required":true'; }
a_not_L3()    { ! ihas '"risk_class":"L3"'; }
a_caller()    { ihas 'src/cart.ts'; }
a_test_found(){ ihas 'src/price.test.ts'; }
a_json_ok()   { json_ok "$(git rev-parse --git-dir)/proofgate-impact.json"; }
a_no_sha_key(){ [ "$(ij | grep -o '"sha":"' | wc -l | tr -d ' ')" = 0 ] && ihas '"head_sha"'; }
a_declared()  { ihas '"no-runtime-driver"' && ihas '"max_achievable_level":"E2"'; }
a_e2e()       { ihas '"max_achievable_level":"E3"' && ihas '"runtime_driver":"commands.e2e"'; }
a_sliced()    { ihas '"risk_class":"L3"' && ihas 'src/payment/charge.ts'; }

caso_tool "impact: docs-only diff → L1 / needs E1"        0 setup_docs a_L1 -- "$IMPACT"
caso_tool "impact: source with a caller → L2 / needs E3"  0 setup_caller a_L2 -- "$IMPACT"
caso_tool "impact: the caller is actually listed"         0 setup_caller a_caller -- "$IMPACT"
caso_tool "impact: the affected test is found"            0 setup_caller a_test_found -- "$IMPACT"
caso_tool "impact: file under auth/ → L3 + skeptic req"   0 setup_auth a_L3 -- "$IMPACT"
caso_tool "impact: sensitive terms in a TEST → not L3"    0 setup_termstest a_not_L3 -- "$IMPACT"
caso_tool "impact: sensitive terms in SOURCE → L3"        0 setup_termssrc a_L3 -- "$IMPACT"
# Found by this gate judging its own 2.7.0 diff: a README that DESCRIBES the
# sensitive-term list is documentation, not a permission check. Scanning docs and
# config for the terms escalated the release that introduced them.
setup_termsdocs() { mkdir -p src; echo 'export const x=1;' > src/a.ts
                    printf 'Terms we watch: bearer, isAdmin, refund, ALTER TABLE.\n' > GUIDE.md
                    printf '{"sensitiveTerms":"bearer|isAdmin|refund"}\n' > cfg.json; }
caso_tool "impact: those same terms in DOCS/CONFIG → not L3" 0 setup_termsdocs a_not_L3 -- "$IMPACT"
caso_tool "impact: anti-slicing — earlier commit counted" 0 setup_sliced a_sliced -- "$IMPACT"
caso_tool "impact: json is valid"                         0 setup_caller a_json_ok -- "$IMPACT"
caso_tool "impact: no bare \"sha\" key (hook grep contract)" 0 setup_caller a_no_sha_key -- "$IMPACT"
caso_tool "impact: no runtime → E3 unreachable, declared" 0 setup_caller a_declared -- "$IMPACT"
caso_tool "impact: commands.e2e → E3 reachable"           0 setup_e2e a_e2e -- "$IMPACT"

# An uncommitted edit is part of the blast radius. caso_tool commits its setup, so
# this one is built by hand.
tmpu="$(mktemp -d)"
( cd "$tmpu" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm base
  printf 'export const x=2;\nexport function brandNew(){return 1}\n' > src/a.ts ) >/dev/null 2>&1
( cd "$tmpu" && PROOFGATE_LIB="$LIB" bash "$IMPACT" --base HEAD </dev/null ) >/dev/null 2>&1
if grep -q '"risk_class":"L2"' "$tmpu/.git/proofgate-impact.json" 2>/dev/null && grep -q 'brandNew' "$tmpu/.git/proofgate-impact.json" 2>/dev/null; then
  echo "PASS  impact: UNCOMMITTED edit is in the radius"; PASS=$((PASS + 1))
else echo "FAIL  impact: uncommitted edit was not counted"; FAIL=$((FAIL + 1)); fi
rm -rf "$tmpu"

# The backend seam. A real LSP client is not a shell script, so impact.sh hands the
# job to `impact.backendCmd` — this proves the contract, and that it is DECLARED.
tmpb="$(mktemp -d)"
( cd "$tmpb" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p src && echo 'export const x=1;' > src/a.ts
  printf '#!/usr/bin/env bash\nwhile IFS= read -r f; do printf "S\\t%%s\\tfakeSym\\tfunction\\t7\\n" "$f"; done\nprintf "C\\tfakeSym\\tsrc/other.ts\\t42\\n"\n' > fake-backend.sh
  chmod +x fake-backend.sh
  printf '{"impact":{"backendCmd":"./fake-backend.sh"}}\n' > proofgate.json
  git add -A && git commit -qm base
  echo 'export const x=2;' > src/a.ts ) >/dev/null 2>&1
( cd "$tmpb" && PROOFGATE_LIB="$LIB" bash "$IMPACT" --base HEAD </dev/null ) >/dev/null 2>&1
if grep -q '"navigation_backend":"external:' "$tmpb/.git/proofgate-impact.json" 2>/dev/null \
   && grep -q '"navigation_confidence":"high"' "$tmpb/.git/proofgate-impact.json" 2>/dev/null \
   && grep -q 'fakeSym' "$tmpb/.git/proofgate-impact.json" 2>/dev/null; then
  echo "PASS  impact: external backend honored + declared high"; PASS=$((PASS + 1))
else echo "FAIL  impact: external backend not honored"; FAIL=$((FAIL + 1)); fi
rm -rf "$tmpb"

# Degradation must be DECLARED, never silent: with a ctags that is not Universal
# (what macOS ships), navigation drops to grep and says so.
tmpc="$(mktemp -d)"; fakebin="$(mktemp -d)"
printf '#!/bin/sh\necho "Exuberant Ctags 5.8"\n' > "$fakebin/ctags"; chmod +x "$fakebin/ctags"
( cd "$tmpc" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm base
  echo 'export function helper(){return 2}' > src/a.ts ) >/dev/null 2>&1
( cd "$tmpc" && PATH="$fakebin:$PATH" PROOFGATE_LIB="$LIB" bash "$IMPACT" --base HEAD </dev/null ) >/dev/null 2>&1
if grep -q '"navigation_backend":"grep"' "$tmpc/.git/proofgate-impact.json" 2>/dev/null \
   && grep -q '"navigation_confidence":"low"' "$tmpc/.git/proofgate-impact.json" 2>/dev/null \
   && grep -q '"no-ctags"' "$tmpc/.git/proofgate-impact.json" 2>/dev/null; then
  echo "PASS  impact: non-Universal ctags → grep backend, declared"; PASS=$((PASS + 1))
else echo "FAIL  impact: degradation not declared"; FAIL=$((FAIL + 1)); fi
rm -rf "$tmpc" "$fakebin"

echo "══ claims: evidence as a record, not as prose ══════════════"
CLAIM="$ROOT/skills/proofgate/scripts/claim.sh"
# A tiny helper: run claim.sh inside a throwaway repo, assert exit + output.
cl_case() { # cl_case <name> <expected-exit> <expect-substr|-> <claim-args...>
  local nome="$1" esperado="$2" substr="$3"; shift 3
  local tmp code=0 out; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t \
      && echo one > a.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
  out="$(cd "$tmp" && PROOFGATE_LIB="$LIB" bash "$CLAIM" "$@" </dev/null 2>&1)" || code=$?
  local ok=1
  [ "$code" = "$esperado" ] || ok=0
  [ "$substr" != "-" ] && { printf '%s' "$out" | grep -q "$substr" || ok=0; }
  if [ "$ok" = 1 ]; then echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado, got $code out=[$out]"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmp"
}

# The refusals. Each one closes a way to record a level nothing supports.
cl_case "claim: --run true → refused"            2 "cannot fail" add --claim c --level E2 --run "true"
cl_case "claim: 'cmd || true' → refused"         2 "cannot fail" add --claim c --level E2 --run "grep x a.txt || true"
cl_case "claim: 'cmd ; exit 0' → refused"        2 "cannot fail" add --claim c --level E2 --run "grep x a.txt ; exit 0"
cl_case "claim: a real pipeline is NOT a no-op"  0 "recorded at E2" add --claim c --level E2 --run "cat a.txt | grep -q one"
cl_case "claim: E1 with no evidence → refused"   2 "needs evidence" add --claim c --level E1
cl_case "claim: E3 without --expect → refused"   2 "UNIQUE TO THE NEW" add --claim c --level E3 --run "cat a.txt"
cl_case "claim: E0 needs nothing"                0 "recorded at E0" add --kind gap --claim "the retry path is untested"
cl_case "claim: red test that PASSES → refused"  2 "must be RED" add --kind red-test --run "grep -q one a.txt"
cl_case "claim: red test that fails → recorded"  0 "recorded at E2" add --kind red-test --run "grep -q ZZZ a.txt"
cl_case "claim: green without --same-as → refused" 2 "same-as" add --kind green-test --run "grep -q one a.txt"
cl_case "claim: unknown --kind → refused"        2 "unknown --kind" add --kind vibes --claim c --level E2 --run "cat a.txt"

# A failed run and an unmatched marker still WRITE the row — at E0, with the reason.
# Silently dropping them is how "not verified" becomes indistinguishable from "fine".
cl_case "claim: failing command → recorded at E0" 0 "recorded at E0" add --claim c --level E2 --run "grep -q ZZZ a.txt"
cl_case "claim: unmatched --expect → E0 + reason" 0 "expect-unmatched" add --claim c --level E3 --run "cat a.txt" --expect "NEWSHA"

# The pair. A green test must re-run the command that was red — a different command
# passing proves a different thing.
tmpg="$(mktemp -d)"
( cd "$tmpg" && git init -q -b main && git config user.email t@t && git config user.name t
  echo one > a.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
RID="$( cd "$tmpg" && PROOFGATE_LIB="$LIB" bash "$CLAIM" add --kind red-test --run "grep -q ZZZ a.txt" </dev/null 2>/dev/null | awk '{print $2}')"
c1=0; ( cd "$tmpg" && PROOFGATE_LIB="$LIB" bash "$CLAIM" add --kind green-test --same-as "$RID" --run "grep -q QQQ a.txt" </dev/null ) >/dev/null 2>&1 || c1=$?
( cd "$tmpg" && echo ZZZ >> a.txt )
c2=0; ( cd "$tmpg" && PROOFGATE_LIB="$LIB" bash "$CLAIM" add --kind green-test --same-as "$RID" --run "grep -q ZZZ a.txt" </dev/null ) >/dev/null 2>&1 || c2=$?
if [ "$c1" = 2 ] && [ "$c2" = 0 ]; then echo "PASS  claim: green must re-run the SAME command"; PASS=$((PASS + 1))
else echo "FAIL  claim: green/red pairing (different-cmd=$c1 same-cmd=$c2)"; FAIL=$((FAIL + 1)); fi
# render is GENERATED: the ledger's content must appear in it, and a bare status cannot.
ROUT="$( cd "$tmpg" && PROOFGATE_LIB="$LIB" bash "$CLAIM" render </dev/null 2>&1 )"
if printf '%s' "$ROUT" | grep -q "grep -q ZZZ a.txt" && printf '%s' "$ROUT" | grep -q "STATUS:"; then
  echo "PASS  claim: render quotes the command that ran"; PASS=$((PASS + 1))
else echo "FAIL  claim: render did not include the evidence [$ROUT]"; FAIL=$((FAIL + 1)); fi
rm -rf "$tmpg"

# An empty ledger renders as NOTHING — not as a tidy-looking block.
tmpe="$(mktemp -d)"
( cd "$tmpe" && git init -q -b main && git config user.email t@t && git config user.name t
  echo one > a.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
EOUT="$( cd "$tmpe" && PROOFGATE_LIB="$LIB" bash "$CLAIM" render </dev/null 2>&1 )"
if printf '%s' "$EOUT" | grep -q "VERIFIED: NOTHING"; then
  echo "PASS  claim: no claims → render says NOTHING"; PASS=$((PASS + 1))
else echo "FAIL  claim: empty ledger did not render as NOTHING"; FAIL=$((FAIL + 1)); fi
rm -rf "$tmpe"

# ── the engine side: required vs achieved, and the three proof states ────────
setup_proofable() { mkdir -p src; echo 'export const x=1;' > src/a.ts
                    printf '{"commands":{"typecheck":"true","test":"true","lint":"true","e2e":"true"}}\n' > proofgate.json; }
a_cannot_prove()  { grep -q '"status":"cannot_prove"' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
a_unproven()      { grep -q '"status":"unproven"' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
a_chain_ok()      { grep -q '"chain_ok":true' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
caso_verify "engine: L2 with no runtime → cannot_prove, not a failure" 0 setup_clean a_cannot_prove
caso_verify "engine: L2 with e2e configured but no claim → unproven"   0 setup_proofable a_unproven
caso_verify "engine: --strict still passes when evidence is unreachable" 0 setup_clean a_true --strict
caso_verify "engine: clean ledger → chain_ok"                          0 setup_clean a_chain_ok

# A row appended by hand — the agent writing its own evidence — breaks the chain.
setup_forged() { mkdir -p src; echo 'export const x=1;' > src/a.ts
                 mkdir -p .git
                 printf '{"id":"c-forged","sha":"%s","kind":"central","level_recorded":"E4","prev":"deadbeef"}\n' "$(git rev-parse HEAD 2>/dev/null || echo x)" > .git/proofgate-claims.jsonl; }
a_chain_fail() { grep -q "ledger-chain" /tmp/pg-cv.out; }
caso_verify "engine: forged ledger row → ledger-chain FAIL" 1 setup_forged a_chain_fail

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
( cd "$tmpf" || exit 1; git init -q -b main; git config user.email t@t; git config user.name t
  printf '{"pushGuard":true}\n' > proofgate.json; mkdir -p .proofgate; cp "$LIB" .proofgate/lib.sh
  git add -A; git commit -qm base
  printf '{"sha":"%s","pass":true}\n' "$(git rev-parse HEAD)" > .git/proofgate-verdict.json ) >/dev/null 2>&1
code=0; ( cd "$tmpf"; printf '%s' "$(ev 'git push origin main')" | bash "$ROOT/hooks/push-guard.sh" ) >/dev/null 2>&1 || code=$?
if [ "$code" = 0 ]; then echo "PASS  push-guard: fresh+pass → allow (exit 0)"; PASS=$((PASS+1)); else echo "FAIL  push-guard: fresh+pass → expected 0 got $code"; FAIL=$((FAIL+1)); fi
rm -rf "$tmpf"

echo "══ hypotheses: what you already ruled out ══════════════════"
HYPO="$ROOT/skills/proofgate/scripts/hypothesis.sh"
hy_repo() { # a repo with a hypothesis ledger, echoed as its path
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t \
      && echo one > a.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
hy() { ( cd "$1" && PROOFGATE_LIB="$LIB" bash "$HYPO" "${@:2}" </dev/null 2>&1 ); }
hy_code() { local d="$1"; shift; local c=0; ( cd "$d" && PROOFGATE_LIB="$LIB" bash "$HYPO" "$@" </dev/null ) >/dev/null 2>&1 || c=$?; printf '%s' "$c"; }
ok_t() { if [ "$1" = 1 ]; then echo "PASS  $2"; PASS=$((PASS + 1)); else echo "FAIL  $2"; FAIL=$((FAIL + 1)); fi; }

D="$(hy_repo)"
hy "$D" open --kind diagnosis --symptom flake --hypothesis "A daemon runs git reset on the repo" >/dev/null
HID="$(hy "$D" list --open | awk '{print $1}' | head -1)"
ok_t "$([ -n "$HID" ] && echo 1 || echo 0)" "hypothesis: open → listed as open"
ok_t "$([ "$(hy_code "$D" confirm "$HID")" = 2 ] && echo 1 || echo 0)" "hypothesis: confirm with no evidence → refused"
hy "$D" refute "$HID" --run "git reflog | grep -q reset" >/dev/null
# NOTE: capture first, then grep the VARIABLE. `producer | grep -q x` under
# `set -o pipefail` reports failure even on a match: grep exits at the first hit,
# the producer dies of SIGPIPE, and pipefail promotes that to the pipeline's status.
# A passing check that looks like a failure is exactly the kind of noise that trains
# people to ignore red.
REFUTED="$(hy "$D" list --refuted)"
ok_t "$(printf '%s' "$REFUTED" | grep -q "$HID" && echo 1 || echo 0)" "hypothesis: refute --run records the observation"
# Silence IS the observation: a `grep -q` probe that finds nothing is what kills an idea.
ok_t "$(printf '%s' "$REFUTED" | grep -q "ABSENT" && echo 1 || echo 0)" "hypothesis: an absent mark is recorded, not left blank"
# Re-proposing the same idea (case/whitespace insensitive) is refused...
ok_t "$([ "$(hy_code "$D" open --kind diagnosis --hypothesis "a daemon   runs GIT RESET on the repo")" = 2 ] && echo 1 || echo 0)" \
     "hypothesis: re-proposing a refuted idea → refused"
# ...but a genuinely different idea is not.
ok_t "$([ "$(hy_code "$D" open --kind diagnosis --hypothesis "The container is recycled between steps")" = 0 ] && echo 1 || echo 0)" \
     "hypothesis: a different idea is still allowed (negative)"
ok_t "$([ "$(hy_code "$D" reopen "$HID")" = 2 ] && echo 1 || echo 0)" "hypothesis: reopen without --new-evidence → refused"
ok_t "$([ "$(hy_code "$D" reopen "$HID" --new-evidence "the daemon now exists on this host")" = 0 ] && echo 1 || echo 0)" \
     "hypothesis: reopen with new evidence → allowed"
rm -rf "$D"

# Strike escalation: the SKILL's "the bar inverts for external causes", mechanised.
D2="$(hy_repo)"
hy "$D2" open --kind diagnosis --symptom stuck --hypothesis "explanation one" >/dev/null
H1="$(hy "$D2" list --open | awk '{print $1}' | head -1)"; hy "$D2" refute "$H1" --observed "ruled out" >/dev/null
hy "$D2" open --kind diagnosis --symptom stuck --hypothesis "explanation two" >/dev/null
H2="$(hy "$D2" list --open | awk '{print $1}' | head -1)"; hy "$D2" refute "$H2" --observed "also ruled out" >/dev/null
THIRD="$(hy "$D2" open --kind diagnosis --symptom stuck --hypothesis "explanation three")"
ok_t "$(printf '%s' "$THIRD" | grep -q ESCALATED && echo 1 || echo 0)" "hypothesis: third try on one symptom → ESCALATED"
ok_t "$(grep -q '"escalated":true' "$D2/.git/proofgate-hypotheses.jsonl" && echo 1 || echo 0)" "hypothesis: escalation is recorded in the ledger"
( cd "$D2" && mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm c ) >/dev/null 2>&1
( cd "$D2" && PROOFGATE_LIB="$LIB" bash "$ROOT/skills/proofgate/scripts/impact.sh" --base HEAD~1 --no-cache </dev/null ) >/dev/null 2>&1
ok_t "$(grep -q '"skeptic_required":true' "$D2/.git/proofgate-impact.json" && echo 1 || echo 0)" "hypothesis: escalation forces skeptic_required in impact"
# A symptom with ONE refutation must NOT escalate — the threshold has to mean something.
D3="$(hy_repo)"
hy "$D3" open --kind diagnosis --symptom once --hypothesis "single idea" >/dev/null
H3="$(hy "$D3" list --open | awk '{print $1}' | head -1)"; hy "$D3" refute "$H3" --observed "ruled out" >/dev/null
SECOND="$(hy "$D3" open --kind diagnosis --symptom once --hypothesis "second idea")"
ok_t "$(printf '%s' "$SECOND" | grep -q ESCALATED && echo 0 || echo 1)" "hypothesis: one refutation does NOT escalate (negative)"
rm -rf "$D2" "$D3"

# ── 93-hypothesis-required ────────────────────────────────────────────────────
plant_fixbranch()   { git checkout -qb fix/login 2>/dev/null; echo 'export const x=2;' > a.ts; }
plant_featbranch()  { git checkout -qb feat/new 2>/dev/null; echo 'export const x=2;' > a.ts; }
plant_fixwithhyp()  { git checkout -qb fix/login 2>/dev/null; echo 'export const x=2;' > a.ts
                      mkdir -p .git; printf '{"id":"h-1","event":"open","kind":"bugfix"}\n' > .git/proofgate-hypotheses.jsonl; }
caso "hypothesis-required: fix branch, empty ledger → WARN" 2 93-hypothesis-required.sh plant_fixbranch
caso "hypothesis-required: feature branch → pass"           0 93-hypothesis-required.sh plant_featbranch
caso "hypothesis-required: fix branch WITH a hypothesis → pass" 0 93-hypothesis-required.sh plant_fixwithhyp

echo "══ edit-guard + session-hook ═══════════════════════════════"
EG="$ROOT/hooks/edit-guard.sh"; SH="$ROOT/hooks/session-hook.sh"
eg_repo() { # <editGuard-true?> <open-bugfix?> <red-test?>
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    printf '{"editGuard":%s}\n' "$1" > proofgate.json
    mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm base
    [ "$2" = yes ] && printf '{"id":"h-1","ts":"t","event":"open","kind":"bugfix","hypothesis":"off by one","cmd":"npm test -- x"}\n' > .git/proofgate-hypotheses.jsonl
    [ "$3" = yes ] && printf '{"id":"c-1","sha":"x","kind":"red-test","hypothesis":"h-1","evidence":{"exit":1}}\n' > .git/proofgate-claims.jsonl
    true ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
eg_run() { local d="$1" f="$2" c=0
  ( cd "$d" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$f" | bash "$EG" ) >/dev/null 2>&1 || c=$?
  printf '%s' "$c"; }
E1="$(eg_repo true yes no)"; E2="$(eg_repo true yes yes)"; E3="$(eg_repo false yes no)"; E4="$(eg_repo true no no)"
ok_t "$([ "$(eg_run "$E1" src/a.ts)" = 2 ] && echo 1 || echo 0)" "edit-guard: open bugfix, no red test → BLOCK"
ok_t "$([ "$(eg_run "$E1" src/a.test.ts)" = 0 ] && echo 1 || echo 0)" "edit-guard: the test file itself → allow"
ok_t "$([ "$(eg_run "$E1" README.md)" = 0 ] && echo 1 || echo 0)" "edit-guard: docs → allow"
ok_t "$([ "$(eg_run "$E2" src/a.ts)" = 0 ] && echo 1 || echo 0)" "edit-guard: red test recorded → allow"
ok_t "$([ "$(eg_run "$E3" src/a.ts)" = 0 ] && echo 1 || echo 0)" "edit-guard: editGuard:false → allow (opt-in)"
ok_t "$([ "$(eg_run "$E4" src/a.ts)" = 0 ] && echo 1 || echo 0)" "edit-guard: no hypothesis at all → allow"
# The block message must actually REACH the agent. It did not for four releases: the
# fail-open `2>/dev/null` wrapper ate it, so a refusal arrived with no reason attached.
MSG="$( cd "$E1" && printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' | bash "$EG" 2>&1 1>/dev/null )"
ok_t "$(printf '%s' "$MSG" | grep -q "red-test" && echo 1 || echo 0)" "edit-guard: the refusal explains itself on stderr"
c=0; ( cd "$E1" && printf 'not json' | bash "$EG" ) >/dev/null 2>&1 || c=$?
ok_t "$([ "$c" = 0 ] && echo 1 || echo 0)" "edit-guard: malformed stdin → fail-open"
c=0; ( cd "$E1" && printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' | PROOFGATE_HOOK_OFF=1 bash "$EG" ) >/dev/null 2>&1 || c=$?
ok_t "$([ "$c" = 0 ] && echo 1 || echo 0)" "edit-guard: PROOFGATE_HOOK_OFF → allow"

# push-guard's message had the same bug; pin it too.
PMSG="$( cd "$E1" && printf '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' | bash "$ROOT/hooks/push-guard.sh" 2>&1 1>/dev/null )"
ok_t "$(printf '%s' "$PMSG" | grep -q "push blocked" && echo 1 || echo 0)" "push-guard: the refusal explains itself on stderr"

# session-hook: the refuted list has to come BACK after a compaction.
SOUT="$( cd "$E1" && printf '{"source":"compact"}' | bash "$SH" 2>/dev/null )"
ok_t "$(printf '%s' "$SOUT" | grep -q "additionalContext" && echo 1 || echo 0)" "session-hook: compact → injects context"
ok_t "$(printf '%s' "$SOUT" | grep -q "off by one" && echo 1 || echo 0)" "session-hook: the open hypothesis survives the compaction"
SEMPTY="$(cd "$E4" && rm -f .git/proofgate-hypotheses.jsonl; cd "$E4" && printf '{"source":"startup"}' | bash "$SH" 2>/dev/null)"
ok_t "$([ -z "$SEMPTY" ] && echo 1 || echo 0)" "session-hook: nothing to say → silent (negative)"
rm -rf "$E1" "$E2" "$E3" "$E4"

echo "══ memory: anchored to code, not to prose ══════════════════"
MEM="$ROOT/skills/proofgate/scripts/memory.sh"
mem_repo() {
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    mkdir -p src && printf 'export const rate = 0.15;\n' > src/pricing.ts
    printf 'export const db = 1;\n' > src/db.ts
    git add -A && git commit -qm base ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
mm() { ( cd "$1" && PROOFGATE_LIB="$LIB" bash "$MEM" "${@:2}" </dev/null 2>&1 ); }
mm_code() { local d="$1"; shift; local c=0; ( cd "$d" && PROOFGATE_LIB="$LIB" bash "$MEM" "$@" </dev/null ) >/dev/null 2>&1 || c=$?; printf '%s' "$c"; }

M1="$(mem_repo)"
# A fact with nothing to anchor it to can never be shown to have gone stale, which is
# the only property that makes stored memory safe to read.
ok_t "$([ "$(mm_code "$M1" add --fact "we use kafka" --class decision)" = 2 ] && echo 1 || echo 0)" \
     "memory: no --anchor → refused"
mm "$M1" add --fact "the 0.15 rate is contractual" --class decision --provenance human --anchor src/pricing.ts >/dev/null
mm "$M1" add --fact "db.ts assumes a single writer" --class inference --provenance agent --anchor src/db.ts >/dev/null
LST="$(mm "$M1" list)"
ok_t "$(printf '%s' "$LST" | grep -q "contractual" && echo 1 || echo 0)" "memory: add → listed"
ok_t "$(printf '%s' "$LST" | grep -cq "stale" && echo 0 || echo 1)" "memory: untouched anchors stay valid (negative)"
REC="$(mm "$M1" recall src/pricing.ts)"
ok_t "$(printf '%s' "$REC" | grep -q "contractual" && echo 1 || echo 0)" "memory: recall by path finds the fact"
ok_t "$(printf '%s' "$REC" | grep -q "single writer" && echo 0 || echo 1)" "memory: recall does not return other files' facts (negative)"

# Move the code the inference was about: the anchor drifts, and the fact is stale.
( cd "$M1" && printf 'export const db = 2;\n' > src/db.ts && git add -A && git commit -qm change ) >/dev/null 2>&1
LST2="$(mm "$M1" list)"
ok_t "$(printf '%s' "$LST2" | grep -q "stale" && echo 1 || echo 0)" "memory: anchor drift → derived stale"
ok_t "$(printf '%s' "$LST2" | grep -q "contractual" && printf '%s' "$LST2" | grep "contractual" | grep -q valid && echo 1 || echo 0)" \
     "memory: the untouched fact is still valid (negative)"
REC2="$(mm "$M1" recall src/db.ts)"
ok_t "$(printf '%s' "$REC2" | grep -q "STALE" && echo 1 || echo 0)" "memory: recall marks the stale fact loudly"

# An AGENT's "decision" expires like the inference it really is — otherwise an agent
# could make its own conclusion permanent policy by choosing a class.
M2="$(mem_repo)"
mm "$M2" add --fact "agent-decided invariant" --class decision --provenance agent --anchor src/db.ts >/dev/null
( cd "$M2" && printf 'export const db = 9;\n' > src/db.ts && git add -A && git commit -qm change ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(mm "$M2" list)" | grep -q "stale" && echo 1 || echo 0)" "memory: an agent's 'decision' expires like an inference"
# An incident never expires — that is the entire point of a scar.
M3="$(mem_repo)"
mm "$M3" add --fact "float rounding cost 3c an invoice for a week" --class incident --provenance human --anchor src/db.ts >/dev/null
( cd "$M3" && printf 'export const db = 9;\n' > src/db.ts && git add -A && git commit -qm change ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(mm "$M3" list)" | grep -q "valid" && echo 1 || echo 0)" "memory: an incident never goes stale (negative)"
ok_t "$([ "$(mm_code "$M3" revoke m-nope --reason x)" = 2 ] && echo 1 || echo 0)" "memory: revoking an unknown id → refused"

# The lesson loop: an incident opens a lesson, and it stays open until something ENFORCES it.
ok_t "$([ -f "$M3/.proofgate/lessons.jsonl" ] && echo 1 || echo 0)" "lessons: an incident opens a lesson"
# shellcheck source=/dev/null
LID="$( cd "$M3" && PROOFGATE_LIB="$LIB" . "$LIB" && pg_lessons_open | awk '{print $1}' | head -1 )"
ok_t "$([ -n "$LID" ] && echo 1 || echo 0)" "lessons: the new lesson is open"
mm "$M3" add --fact "documented in the pricing README" --class decision --provenance human --anchor src/db.ts --resolves "$LID" >/dev/null
# shellcheck source=/dev/null
LEFT="$( cd "$M3" && PROOFGATE_LIB="$LIB" . "$LIB" && pg_lessons_open )"
ok_t "$([ -z "$LEFT" ] && echo 1 || echo 0)" "lessons: --resolves closes it"
rm -rf "$M1" "$M2" "$M3"

# ── 97-memory-stale / 98-unlearned-lessons ───────────────────────────────────
plant_stalemem() {
  mkdir -p src .proofgate && printf 'export const db = 1;\n' > src/db.ts
  git add -A >/dev/null 2>&1; git commit -qm seed >/dev/null 2>&1
  printf '{"id":"m-1","ts":"t","event":"add","ref":null,"fact":"db assumes one writer","class":"inference","provenance":"agent","anchors":[{"path":"src/db.ts","blob":"0000000000000000000000000000000000000000","line":0,"line_sha":""}],"created_sha":"x","ttl_diffs":20,"guard":null,"resolves":null,"via":"t","prev":""}\n' > .proofgate/memory.jsonl
  printf 'export const db = 2;\n' > src/db.ts
}
plant_validmem() {
  mkdir -p src .proofgate && printf 'export const other = 1;\n' > src/other.ts
  printf 'export const db = 1;\n' > src/db.ts
  git add -A >/dev/null 2>&1; git commit -qm seed >/dev/null 2>&1
  printf '{"id":"m-1","ts":"t","event":"add","ref":null,"fact":"db assumes one writer","class":"inference","provenance":"agent","anchors":[{"path":"src/db.ts","blob":"%s","line":0,"line_sha":""}],"created_sha":"x","ttl_diffs":20,"guard":null,"resolves":null,"via":"t","prev":""}\n' "$(git hash-object src/db.ts)" > .proofgate/memory.jsonl
  printf 'export const other = 2;\n' > src/other.ts
}
caso "memory-stale: stale fact anchored to a changed file → WARN" 2 97-memory-stale.sh plant_stalemem
caso "memory-stale: fact valid, other file changed → pass"       0 97-memory-stale.sh plant_validmem
caso "memory-stale: no memory at all → pass"                     0 97-memory-stale.sh plant_clean

plant_openlesson()  { echo 'x' > a.ts; mkdir -p .proofgate
                      printf '{"id":"L-1","ts":"t","event":"open","source":"incident","ref":"m-1","head_sha":"x","text":"float rounding","resolved_by":null,"until":0,"prev":""}\n' > .proofgate/lessons.jsonl; }
plant_donelesson()  { plant_openlesson
                      printf '{"id":"L-1","ts":"t","event":"resolve","source":"","ref":"","head_sha":"x","text":"","resolved_by":{"kind":"guard","ref":"g"},"until":0,"prev":"x"}\n' >> .proofgate/lessons.jsonl; }
# A comment in an ordinary file is level 2 wearing level 4's clothes — it must NOT count.
plant_fakeenforce() { plant_openlesson; printf '# proofgate-lesson: L-1\n' > NOTES.md; }
caso "lessons: an open lesson → WARN"                      2 98-unlearned-lessons.sh plant_openlesson
caso "lessons: resolved → pass"                            0 98-unlearned-lessons.sh plant_donelesson
caso "lessons: a comment in a NON-guard file → still WARN" 2 98-unlearned-lessons.sh plant_fakeenforce
caso "lessons: no lessons file → pass"                     0 98-unlearned-lessons.sh plant_clean

echo "══ edit-notice: memory + live guards at edit time ══════════"
EN="$ROOT/hooks/edit-notice.sh"
en_repo() { # <liveGuards> <with-memory>
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    printf '{"liveGuards":%s}\n' "$1" > proofgate.json
    mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm base
    if [ "$2" = yes ]; then mkdir -p .proofgate
      printf '{"id":"m-1","ts":"t","event":"add","ref":null,"fact":"a.ts owns the cache","class":"decision","provenance":"human","anchors":[{"path":"src/a.ts","blob":"%s","line":0,"line_sha":""}],"created_sha":"x","ttl_diffs":20,"guard":null,"resolves":null,"via":"t","prev":""}\n' "$(git hash-object src/a.ts)" > .proofgate/memory.jsonl
    fi ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
en_run() { ( cd "$1" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/a.ts"}}' "$1" | bash "$EN" 2>/dev/null ); }
N1="$(en_repo true yes)"
ok_t "$(printf '%s' "$(en_run "$N1")" | grep -q "owns the cache" && echo 1 || echo 0)" "edit-notice: recalls memory anchored to the edited file"
# The live half: a credential pasted into the file is reported NOW, not at the gate.
( cd "$N1" && printf 'export const x=1;\nconst k = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";\n' > src/a.ts )
ok_t "$(printf '%s' "$(en_run "$N1")" | grep -q "secrets:" && echo 1 || echo 0)" "edit-notice: a live guard fires on the working tree"
N2="$(en_repo false no)"
( cd "$N2" && printf 'export const x=1;\nconst k = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";\n' > src/a.ts )
ok_t "$([ -z "$(en_run "$N2")" ] && echo 1 || echo 0)" "edit-notice: liveGuards off and no memory → silent (negative)"
rm -rf "$N1" "$N2"

# install --uninstall must not take the team's committed memory with it.
U="$(mktemp -d)"
( cd "$U" && git init -q -b main && git config user.email t@t && git config user.name t && echo x > a.txt && git add -A && git commit -qm base
  bash "$ROOT/install.sh" >/dev/null 2>&1
  mkdir -p .proofgate && printf '{"id":"m-1","fact":"years of knowledge"}\n' > .proofgate/memory.jsonl
  bash "$ROOT/install.sh" --uninstall >/dev/null 2>&1 ) >/dev/null 2>&1
ok_t "$([ -f "$U/.proofgate/memory.jsonl" ] && echo 1 || echo 0)" "install: --uninstall keeps memory.jsonl (it is content, not tooling)"
ok_t "$([ -f "$U/.proofgate/verify.sh" ] && echo 0 || echo 1)" "install: --uninstall still removes the machinery"
rm -rf "$U"

echo "══ experiments + prototype mode ════════════════════════════"
EXP="$ROOT/skills/proofgate/scripts/experiment.sh"; MODE="$ROOT/skills/proofgate/scripts/mode.sh"
xp_repo() {
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    mkdir -p src && printf 'export const limit = 10;\n' > src/cfg.ts && git add -A && git commit -qm base
    PROOFGATE_LIB="$LIB" bash "$HYPO" open --kind diagnosis --symptom perf \
      --hypothesis "the limit of 10 is the bottleneck" --cmd "grep limit src/cfg.ts" ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
xp() { ( cd "$1" && PROOFGATE_LIB="$LIB" bash "$EXP" "${@:2}" </dev/null 2>&1 ); }
X1="$(xp_repo)"
XID="$( cd "$X1" && PROOFGATE_LIB="$LIB" bash "$HYPO" list --open </dev/null 2>/dev/null | awk '{print $1}' | head -1 )"
xc=0; ( cd "$X1" && PROOFGATE_LIB="$LIB" bash "$EXP" h-nope -- "echo hi" ) >/dev/null 2>&1 || xc=$?
ok_t "$([ "$xc" = 2 ] && echo 1 || echo 0)" "experiment: unknown hypothesis → refused"
ok_t "$(printf '%s' "$(xp "$X1" "$XID" -- "cat src/cfg.ts")" | grep -q "limit = 10" && echo 1 || echo 0)" \
     "experiment: runs the command in a worktree"
ok_t "$([ "$(ls "$X1/.git/proofgate-exp" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && echo 1 || echo 0)" \
     "experiment: the worktree is removed afterwards"
ok_t "$(grep -q '"event":"experiment"' "$X1/.git/proofgate-hypotheses.jsonl" && echo 1 || echo 0)" \
     "experiment: the result is recorded against the hypothesis"
# Without --dirty the worktree is HEAD: an experiment about the change you are making
# would otherwise silently run against the code as it was before you made it.
( cd "$X1" && printf 'export const limit = 999;\n' > src/cfg.ts )
ok_t "$(printf '%s' "$(xp "$X1" "$XID" -- "cat src/cfg.ts")" | grep -q "999" && echo 0 || echo 1)" \
     "experiment: without --dirty it sees the committed state (negative)"
ok_t "$(printf '%s' "$(xp "$X1" "$XID" --dirty -- "cat src/cfg.ts")" | grep -q "999" && echo 1 || echo 0)" \
     "experiment: --dirty carries the uncommitted work in"
ok_t "$(printf '%s' "$(xp "$X1" "$XID" -- "exit 3")" | grep -q "exit 3" && echo 1 || echo 0)" \
     "experiment: a failing command records its exit code"
# It must never close the hypothesis: an experiment is an observation, not a verdict.
ok_t "$(printf '%s' "$( cd "$X1" && PROOFGATE_LIB="$LIB" bash "$HYPO" list --open </dev/null 2>/dev/null)" | grep -q "$XID" && echo 1 || echo 0)" \
     "experiment: never auto-confirms the hypothesis (negative)"
# Parallel jobs must not collide: composing a path from the clock and $$ produced the
# SAME name for two jobs started in one second, and the second worktree failed.
PAR="$(xp "$X1" --parallel "$XID::echo one; sleep 1" "$XID::echo two; sleep 1" "$XID::echo three; sleep 1")"
ok_t "$([ "$(printf '%s' "$PAR" | grep -c 'experiment: exit 0' | tr -d ' ')" = 3 ] && echo 1 || echo 0)" \
     "experiment: --parallel runs three at once without colliding"
ok_t "$([ "$(ls "$X1/.git/proofgate-exp" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && echo 1 || echo 0)" \
     "experiment: parallel runs leave no worktrees behind"
INP="$(xp "$X1" "$XID" --in-place -- "echo mutated > scratch.txt")"
ok_t "$(printf '%s' "$INP" | grep -q "tree-mutated" && echo 1 || echo 0)" \
     "experiment: --in-place declares that the run changed the tree"
rm -rf "$X1"

# ── prototype mode ───────────────────────────────────────────────────────────
md_repo() {
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    printf '{"stopGuard":true,"editGuard":true}\n' > proofgate.json
    mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm base
    printf '{"id":"h-1","ts":"t","event":"open","kind":"bugfix","hypothesis":"x","cmd":"t"}\n' > .git/proofgate-hypotheses.jsonl ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
hookrc() { local d="$1" h="$2" j="$3" c=0; ( cd "$d" && printf '%s' "$j" | bash "$ROOT/hooks/$h" ) >/dev/null 2>&1 || c=$?; printf '%s' "$c"; }
D1="$(md_repo)"
EDIT_EV='{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
PUSH_EV='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
ok_t "$([ "$(hookrc "$D1" edit-guard.sh "$EDIT_EV")" = 2 ] && echo 1 || echo 0)" "mode: before — the edit-guard blocks"
( cd "$D1" && PROOFGATE_LIB="$LIB" bash "$MODE" on ) >/dev/null 2>&1
ok_t "$([ -f "$D1/.git/proofgate-mode" ] && echo 1 || echo 0)" "mode: on writes the marker"
ok_t "$([ "$(hookrc "$D1" edit-guard.sh "$EDIT_EV")" = 0 ] && echo 1 || echo 0)" "mode: the edit-guard stands down"
STOPOUT="$( cd "$D1" && printf '{}' | bash "$ROOT/hooks/stop-guard.sh" 2>/dev/null )"
ok_t "$(printf '%s' "$STOPOUT" | grep -q '"decision":"block"' && echo 0 || echo 1)" "mode: the stop-guard stands down"
# The one that must NOT relax. A mode that turned this off would be the bypass renamed.
ok_t "$([ "$(hookrc "$D1" push-guard.sh "$PUSH_EV")" = 2 ] && echo 1 || echo 0)" "mode: the PUSH is still blocked"
PBANNER="$( cd "$D1" && printf '{}' | bash "$ROOT/hooks/prompt-hook.sh" 2>/dev/null )"
ok_t "$(printf '%s' "$PBANNER" | grep -q "PROTOTYPE MODE" && echo 1 || echo 0)" "mode: every prompt carries the banner"
CAP="$( cd "$D1" && PROOFGATE_LIB="$LIB" bash "$CLAIM" add --claim "works" --level E3 --run "cat src/a.ts" --expect "const x" </dev/null 2>&1 )"
ok_t "$(printf '%s' "$CAP" | grep -q "prototype-mode" && echo 1 || echo 0)" "mode: claims are capped at E1 while it is on"
RND="$( cd "$D1" && PROOFGATE_LIB="$LIB" bash "$CLAIM" render </dev/null 2>&1 )"
ok_t "$(printf '%s' "$RND" | grep -q "UNVERIFIED PROTOTYPE" && echo 1 || echo 0)" "mode: the status block says so"
( cd "$D1" && PROOFGATE_LIB="$LIB" bash "$MODE" off ) >/dev/null 2>&1
ok_t "$([ "$(hookrc "$D1" edit-guard.sh "$EDIT_EV")" = 2 ] && echo 1 || echo 0)" "mode: off restores the full gate"
PB2="$( cd "$D1" && printf '{}' | bash "$ROOT/hooks/prompt-hook.sh" 2>/dev/null )"
ok_t "$([ -z "$PB2" ] && echo 1 || echo 0)" "mode: off → the prompt hook is silent (negative)"
rm -rf "$D1"
a_mode_normal() { grep -q '"mode":"normal"' "$(git rev-parse --git-dir)/proofgate-verdict.json"; }
caso_verify "engine: verdict records the mode" 0 setup_clean a_mode_normal

echo "══ skeptic panel: refutations held to their own standard ═══"
SKEP="$ROOT/skills/proofgate/scripts/skeptic.sh"
sk_repo() {
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    echo one > a.txt && git add -A && git commit -qm base
    PROOFGATE_LIB="$LIB" bash "$CLAIM" add --claim "parser handles empty" --level E2 --run "cat a.txt | grep -q one" ) >/dev/null 2>&1
  printf '%s' "$tmp"
}
sk_record() { ( cd "$1" && printf '%s\n' "$2" | PROOFGATE_LIB="$LIB" bash "$SKEP" record --agent "${3:-gate-skeptic}" 2>&1 ); }
sk_json() { cat "$1/.git/proofgate-skeptic.json" 2>/dev/null; }

S1="$(sk_repo)"
# A refutation whose command really fails is real, and becomes a lesson.
sk_record "$S1" "REFUTED - :: the empty case is not covered :: repro: grep -q ZZZ a.txt" >/dev/null
J="$(sk_json "$S1")"
ok_t "$(printf '%s' "$J" | grep -q '"verdict":"REFUTED"' && echo 1 || echo 0)" "skeptic: a reproducing refutation stands"
ok_t "$(printf '%s' "$J" | grep -q '"reproduced":true' && echo 1 || echo 0)" "skeptic: the repro command was actually re-run"
ok_t "$([ -f "$S1/.proofgate/lessons.jsonl" ] && echo 1 || echo 0)" "skeptic: a surviving refutation opens a lesson"
rm -rf "$S1"

# The symmetry. A skeptic asserting a break with no command has produced an E0 claim —
# the same failure it exists to catch, and more expensive, because it sends people to
# fix what was never broken.
S2="$(sk_repo)"
sk_record "$S2" "REFUTED - :: this probably breaks under concurrency :: repro: -" >/dev/null
J2="$(sk_json "$S2")"
ok_t "$(printf '%s' "$J2" | grep -q '"verdict":"UNPROVEN","original_verdict":"REFUTED"' && echo 1 || echo 0)" \
     "skeptic: REFUTED with no repro → downgraded to UNPROVEN"
ok_t "$(printf '%s' "$J2" | grep -q 'no reproducing command' && echo 1 || echo 0)" "skeptic: the downgrade says why"
rm -rf "$S2"

S3="$(sk_repo)"
sk_record "$S3" "REFUTED - :: the config is never read :: repro: cat a.txt" >/dev/null
J3="$(sk_json "$S3")"
ok_t "$(printf '%s' "$J3" | grep -q '"verdict":"UNPROVEN"' && echo 1 || echo 0)" \
     "skeptic: REFUTED whose command PASSES → downgraded"
ok_t "$(printf '%s' "$J3" | grep -q '"reproduced":false' && echo 1 || echo 0)" "skeptic: the failed reproduction is recorded"
rm -rf "$S3"

# A skeptic cannot RAISE evidence either: agreement is not a run.
S4="$(sk_repo)"
SCID4="$( cd "$S4" && PROOFGATE_LIB="$LIB" bash "$CLAIM" list </dev/null 2>/dev/null | awk '{print $1}' | head -1 )"
sk_record "$S4" "CONFIRMED $SCID4 :: I read the test and it looks right :: repro: -" >/dev/null
ok_t "$(printf '%s' "$(sk_json "$S4")" | grep -q '"level_cap":"E2"' && echo 1 || echo 0)" \
     "skeptic: CONFIRMED is capped at the level the ledger recorded"
ok_t "$([ "$( cd "$S4" && PROOFGATE_LIB="$LIB" bash "$SKEP" status </dev/null 2>/dev/null )" = present ] && echo 1 || echo 0)" \
     "skeptic: status is present for HEAD"
( cd "$S4" && echo two > b.txt && git add -A && git commit -qm moved ) >/dev/null 2>&1
ok_t "$([ "$( cd "$S4" && PROOFGATE_LIB="$LIB" bash "$SKEP" status </dev/null 2>/dev/null )" = stale ] && echo 1 || echo 0)" \
     "skeptic: a pass recorded before the code moved is STALE (negative)"
rm -rf "$S4"

# ── 99-skeptic-required ──────────────────────────────────────────────────────
plant_l3_nopass() { mkdir -p src/auth .git && echo 'export const login = (u) => u;' > src/auth/login.ts
                    printf '{"schemaVersion":1,"head_sha":"x","risk_class":"L3","skeptic_required":true,"risk_reasons":["auth"]}\n' > .git/proofgate-impact.json; }
plant_l2()        { mkdir -p src .git && echo 'export const x=1;' > src/a.ts
                    printf '{"schemaVersion":1,"head_sha":"x","risk_class":"L2","skeptic_required":false,"risk_reasons":[]}\n' > .git/proofgate-impact.json; }
plant_l3_stale()  { plant_l3_nopass
                    printf '{"schemaVersion":1,"head_sha":"deadbeef","agents":["gate-skeptic","security-skeptic"],"findings":[]}\n' > .git/proofgate-skeptic.json; }
plant_l3_partial(){ plant_l3_nopass; git add -A >/dev/null 2>&1; git commit -qm x >/dev/null 2>&1
                    printf '{"schemaVersion":1,"head_sha":"%s","agents":["gate-skeptic"],"findings":[]}\n' "$(git rev-parse HEAD)" > .git/proofgate-skeptic.json; }
plant_l3_ok()     { plant_l3_nopass; git add -A >/dev/null 2>&1; git commit -qm x >/dev/null 2>&1
                    printf '{"schemaVersion":1,"head_sha":"%s","agents":["gate-skeptic","security-skeptic"],"findings":[{"agent":"security-skeptic","verdict":"UNPROVEN"}]}\n' "$(git rev-parse HEAD)" > .git/proofgate-impact.tmp
                    printf '{"schemaVersion":1,"head_sha":"%s","agents":["gate-skeptic","security-skeptic"],"findings":[{"agent":"security-skeptic","verdict":"UNPROVEN"}]}\n' "$(git rev-parse HEAD)" > .git/proofgate-skeptic.json
                    rm -f .git/proofgate-impact.tmp; }
plant_l3_open()   { plant_l3_nopass; git add -A >/dev/null 2>&1; git commit -qm x >/dev/null 2>&1
                    printf '{"schemaVersion":1,"head_sha":"%s","agents":["gate-skeptic","security-skeptic"],"findings":[{"agent":"security-skeptic","verdict":"REFUTED"}]}\n' "$(git rev-parse HEAD)" > .git/proofgate-skeptic.json; }
caso "skeptic-required: L3 with no pass → WARN"            2 99-skeptic-required.sh plant_l3_nopass
caso "skeptic-required: L2 → not applicable"               0 99-skeptic-required.sh plant_l2
caso "skeptic-required: pass from another commit → WARN"   2 99-skeptic-required.sh plant_l3_stale
caso "skeptic-required: security-skeptic missing → WARN"   2 99-skeptic-required.sh plant_l3_partial
# These two need the skeptic record to name the FINAL head, and `caso` commits once more
# after its setup runs — so they are built directly instead of through that harness.
sk_guard_case() { # sk_guard_case <name> <expected-exit> <verdict-in-record>
  local nome="$1" esperado="$2" verdict="$3" tmp code=0
  tmp="$(mktemp -d)"
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m base
    mkdir -p src/auth && echo 'export const login = (u) => u;' > src/auth/login.ts
    git add -A && git commit -qm change
    printf '{"schemaVersion":1,"head_sha":"x","risk_class":"L3","skeptic_required":true,"risk_reasons":["auth"]}\n' > .git/proofgate-impact.json
    printf '{"schemaVersion":1,"head_sha":"%s","agents":["gate-skeptic","security-skeptic"],"findings":[{"agent":"security-skeptic","verdict":"%s"}]}\n' \
      "$(git rev-parse HEAD)" "$verdict" > .git/proofgate-skeptic.json ) >/dev/null 2>&1
  ( cd "$tmp" && PROOFGATE_BASE="HEAD~1" PROOFGATE_LIB="$LIB" PROOFGATE_CFG="proofgate.json" \
      bash "$GUARDS/99-skeptic-required.sh" ) >/dev/null 2>&1 || code=$?
  if [ "$code" = "$esperado" ]; then echo "PASS  $nome (exit $code)"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado, got $code"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmp"
}
sk_guard_case "skeptic-required: full pass, nothing reproducing → pass" 0 UNPROVEN
sk_guard_case "skeptic-required: a reproducing refutation is open → FAIL" 1 REFUTED

echo "══ calibration: is a guard earning its noise? ══════════════"
CAL="$(mktemp -d)"
CALREMOTE="$(mktemp -d)"; ( cd "$CALREMOTE" && git init -q --bare ) >/dev/null 2>&1
# A bare remote, as caso_verify does: without an origin the engine cannot resolve a diff
# base, so no guard runs and no calibration event is ever recorded.
( cd "$CAL" && git init -q -b main && git config user.email t@t && git config user.name t
  printf '{"commands":{"typecheck":"true","test":"true","lint":"true"}}\n' > proofgate.json
  echo x > a.txt && git add -A && git commit -qm base
  git remote add origin "$CALREMOTE" && git push -qu origin main && git checkout -q -b feature
  for i in 1 2 3; do printf 'debugger;\nconst a%s = 1;\n' "$i" > a.ts; git add -A; git commit -qm "c$i"
    PROOFGATE_LIB="$LIB" bash "$VERIFY" </dev/null; done ) >/dev/null 2>&1
CALOUT="$( cd "$CAL" && PROOFGATE_LIB="$LIB" bash "$VERIFY" --calibration </dev/null 2>/dev/null )"
ok_t "$(printf '%s' "$CALOUT" | grep -q 'debug-leftovers' && echo 1 || echo 0)" "calibration: a firing guard is counted"
ok_t "$(printf '%s' "$CALOUT" | grep -E 'debug-leftovers' | grep -qE '[1-9]' && echo 1 || echo 0)" "calibration: the fired count is not empty"
# The report must never edit configuration — automating the erosion it measures would
# be the worst possible version of this feature.
CFG_BEFORE="$(pg_sha1 "$CAL/proofgate.json" 2>/dev/null || true)"
( cd "$CAL" && PROOFGATE_LIB="$LIB" bash "$VERIFY" --calibration ) >/dev/null 2>&1
ok_t "$([ "$CFG_BEFORE" = "$(pg_sha1 "$CAL/proofgate.json" 2>/dev/null || true)" ] && echo 1 || echo 0)" \
     "calibration: reporting never edits proofgate.json"
rm -rf "$CAL" "$CALREMOTE"

echo "══ mutate: mutation as proof of test ════════════════════════"
# The two cases CONTRIBUTING requires: it must FIRE on the sin (a test that
# cannot see its own subject) and stay SILENT on the clean case (a test that
# catches the break). Plus the three loud-failure modes, because a verification
# tool whose failure looks like success is the exact thing this tool replaces.
MUT="$ROOT/skills/proofgate/scripts/mutate.mjs"
mut_fixture() { # mut_fixture <dir> <assertion-body>
  mkdir -p "$1"
  cat > "$1/rule.mjs" <<'JS'
export const allow = (n) => n >= 3 && n <= 10;
JS
  cat > "$1/check.mjs" <<JS
import { allow } from "./rule.mjs";
$2
JS
}
mut_case() { # mut_case <name> <assertion-body> <mutation-json> <expected-exit>
  local nome="$1" corpo="$2" mut="$3" esperado="$4" dir code
  dir="$(mktemp -d)"
  mut_fixture "$dir" "$corpo"
  code=0
  printf '%s\n' "$mut" | ( cd "$dir" && node "$MUT" rule.mjs -- node check.mjs ) >/dev/null 2>&1 || code=$?
  if [ "$code" = "$esperado" ]; then echo "PASS  $nome"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — expected exit $esperado got $code"; FAIL=$((FAIL + 1)); fi
  rm -rf "$dir"
}

if command -v node >/dev/null 2>&1; then
  # SIN: the test only ever checks the lower bound, so removing the upper bound
  # changes nothing it looks at. The mutation SURVIVES → exit 1.
  mut_case "mutate: blind test → survivor reported (exit 1)" \
    'if (allow(5) !== true) process.exit(1);' \
    '{"name":"upper bound removed","from":"n >= 3 && n <= 10","to":"n >= 3"}' 1

  # CLEAN: the test pins both bounds, so the same mutation is caught → exit 0.
  mut_case "mutate: seeing test → mutation killed (exit 0)" \
    'if (allow(5) !== true || allow(99) !== false) process.exit(1);' \
    '{"name":"upper bound removed","from":"n >= 3 && n <= 10","to":"n >= 3"}' 0

  # Silence is never green.
  mut_case "mutate: empty stdin → refuses (exit 2)" \
    'if (allow(5) !== true) process.exit(1);' '' 2

  # A non-unique search string would edit the wrong place and lie confidently.
  mut_case "mutate: ambiguous 'from' → refuses (exit 2)" \
    'if (allow(5) !== true) process.exit(1);' \
    '{"name":"ambiguous","from":"n ","to":"x "}' 2

  # Red baseline: "killed" would be the pre-existing breakage, not the mutation.
  mut_case "mutate: red baseline → refuses (exit 2)" \
    'process.exit(1);' \
    '{"name":"upper bound removed","from":"n >= 3 && n <= 10","to":"n >= 3"}' 2

  # The source file must come back, even after a run that reported survivors.
  dir="$(mktemp -d)"; mut_fixture "$dir" 'if (allow(5) !== true) process.exit(1);'
  antes="$(cat "$dir/rule.mjs")"
  printf '%s\n' '{"name":"x","from":"n >= 3 && n <= 10","to":"n >= 3"}' \
    | ( cd "$dir" && node "$MUT" rule.mjs -- node check.mjs ) >/dev/null 2>&1 || true
  if [ "$antes" = "$(cat "$dir/rule.mjs")" ]; then
    echo "PASS  mutate: source restored after the run"; PASS=$((PASS + 1))
  else echo "FAIL  mutate: source NOT restored — the tool corrupted the file"; FAIL=$((FAIL + 1)); fi
  rm -rf "$dir"
else
  echo "SKIP  mutate (no node)"
fi

echo "══ config walkers (zero-dep fallback) ═══════════════════════"
# Regression (found by the SLD retro-port review): a jq-style quoted key like
# `.severity."pii-logging"` must resolve under the node AND python fallbacks too —
# the quotes are literal to a naive split, so a hyphenated key silently returned
# empty, which silently DOWNGRADED the pii-logging→fail LGPD elevation on any box
# without jq. Pin all three parsers on the exact path.
# shellcheck source=/dev/null
. "$LIB"
jq_walk()   { jq -c -r "$2 // empty" "$1" 2>/dev/null; }
node_walk() { node -e "$_PG_NODE_WALK" "$1" "$2" 2>/dev/null; }
py_walk()   { python3 -c "$_PG_PY_WALK" "$1" "$2" 2>/dev/null; }
walk_case() { # walk_case <name> <parser-fn>
  local nome="$1"; shift
  printf '{"severity":{"pii-logging":"fail"}}\n' > /tmp/pg-walk.json
  local got; got="$("$@" /tmp/pg-walk.json '.severity."pii-logging"' 2>/dev/null)"
  if [ "$got" = "fail" ]; then echo "PASS  $nome"; PASS=$((PASS + 1))
  else echo "FAIL  $nome — quoted-key lookup returned [$got], expected [fail]"; FAIL=$((FAIL + 1)); fi
  rm -f /tmp/pg-walk.json
}
command -v jq      >/dev/null 2>&1 && walk_case "walker: quoted key resolves (jq)"     jq_walk     || echo "SKIP  jq walker (no jq)"
command -v node    >/dev/null 2>&1 && walk_case "walker: quoted key resolves (node)"   node_walk   || echo "SKIP  node walker (no node)"
command -v python3 >/dev/null 2>&1 && walk_case "walker: quoted key resolves (python)" py_walk     || echo "SKIP  python walker (no python3)"

echo "══ proof: the evidence travels with the commit ═════════════"
PROOF="$ROOT/skills/proofgate/scripts/proof.sh"
pf_repo() { # a sealed-ready repo: real remote, a passing verdict, a claim on HEAD
  local tmp remote; tmp="$(mktemp -d)"; remote="$(mktemp -d)"
  ( cd "$remote" && git init -q --bare ) >/dev/null 2>&1
  ( cd "$tmp" && git init -q -b main && git config user.email t@t && git config user.name t
    printf '{"commands":{"typecheck":"true","test":"true","lint":"true","e2e":"true"}}\n' > proofgate.json
    mkdir -p src && echo 'export const x=1;' > src/a.ts && git add -A && git commit -qm base
    git remote add origin "$remote" && git push -qu origin main && git checkout -q -b f
    echo 'export const x=2;' > src/a.ts && git add -A && git commit -qm change
    # A command containing a backslash escape: this is the shape that broke replay.
    PROOFGATE_LIB="$LIB" bash "$CLAIM" add --claim "the marker is served" --level E3 \
      --run "printf 'calc=3\\n'; printf 'build:v2\\n'" --expect 'build:v2'
    PROOFGATE_LIB="$LIB" bash "$VERIFY" </dev/null ) >/dev/null 2>&1
  printf '%s %s' "$tmp" "$remote"
}
pf() { ( cd "$1" && PROOFGATE_LIB="$LIB" bash "$PROOF" "${@:2}" </dev/null 2>&1 ); }

# shellcheck disable=SC2046  # pf_repo prints "<repo> <remote>"; the split is the point
set -- $(pf_repo); P1="$1"; PR1="$2"
ok_t "$(printf '%s' "$(pf "$P1" seal)" | grep -q "sealed to" && echo 1 || echo 0)" "proof: seal writes a note on HEAD"
ok_t "$([ "$(pf "$P1" verify)" = "verified" ] && echo 1 || echo 0)" "proof: verify passes on an untouched bundle"
# Tampering AFTER the seal is what the hashes are for.
( cd "$P1" && git notes --ref=refs/notes/proofgate show HEAD | sed 's/"pass":true/"pass":false/'     | git notes --ref=refs/notes/proofgate add -f -F - HEAD ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(pf "$P1" verify)" | grep -q "tampered" && echo 1 || echo 0)" "proof: an edited note is detected as tampered"
( cd "$P1" && git notes --ref=refs/notes/proofgate remove HEAD ) >/dev/null 2>&1
pf "$P1" seal >/dev/null
# Replay must re-run the command AS RECORDED. It used to run the JSON-escaped form —
# a different command from the one being checked, in the component whose only job is
# confirming that recorded evidence still reproduces.
RP="$(pf "$P1" replay)"
ok_t "$(printf '%s' "$RP" | grep -q "the recorded evidence reproduces" && echo 1 || echo 0)" "proof: replay re-runs the evidence and it reproduces"
ok_t "$(printf '%s' "$RP" | grep -q "output hash matched 1" && echo 1 || echo 0)"      "proof: replay runs the command as recorded, not its escaped form"
# An amend makes a different commit; evidence about the old one is not evidence about it.
( cd "$P1" && git commit -q --amend --no-edit ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(pf "$P1" verify)" | grep -q "missing" && echo 1 || echo 0)" "proof: the note does not survive an amend (by design)"
rm -rf "$P1" "$PR1"

# Refusals: a seal that does not describe this exact commit attests to nothing.
# shellcheck disable=SC2046
set -- $(pf_repo); P2="$1"; PR2="$2"
( cd "$P2" && echo 'export const x=3;' > src/a.ts && git add -A && git commit -qm later ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(pf "$P2" seal)" | grep -q "different commit" && echo 1 || echo 0)" "proof: seal refuses a verdict from another commit"
( cd "$P2" && git reset -q --hard HEAD~1 && echo dirty > dirty.txt ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(pf "$P2" seal)" | grep -q "working tree is dirty" && echo 1 || echo 0)" "proof: seal refuses a dirty tree"
rm -rf "$P2" "$PR2"

P3="$(mktemp -d)"
( cd "$P3" && git init -q -b main && git config user.email t@t && git config user.name t && echo x > a.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
ok_t "$(printf '%s' "$(pf "$P3" seal)" | grep -q "no verdict" && echo 1 || echo 0)" "proof: seal refuses without a verdict"
rm -rf "$P3"

# pg_json_field is what makes replay correct — pin it directly on the escaping that broke.
# shellcheck source=/dev/null
PJF="$( . "$LIB"; pg_json_field '{"evidence":{"cmd":"printf '"'"'a\\nb'"'"'","exit":0}}' '.evidence.cmd' )"
ok_t "$([ "$PJF" = "printf 'a\nb'" ] && echo 1 || echo 0)" "lib: pg_json_field unescapes a stored command correctly"

# Evidence must survive the COMMIT that packages the code it describes, and must not
# survive a change to that code. Keying claims on the HEAD sha alone failed the first
# half: `git commit` orphaned every claim recorded before it, and a delivery with a full
# ledger rendered as VERIFIED: NOTHING. Found by the end-to-end run, not by a unit test —
# every piece was behaving exactly as specified.
CID="$(mktemp -d)"
( cd "$CID" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p src && echo 'a' > src/f.ts && git add -A && git commit -qm base
  echo 'b' > src/f.ts
  PROOFGATE_LIB="$LIB" bash "$CLAIM" add --claim "b is there" --level E2 --run "cat src/f.ts | grep -q b"
  git add -A && git commit -qm change ) >/dev/null 2>&1
ok_t "$([ -n "$( cd "$CID" && PROOFGATE_LIB="$LIB" bash "$CLAIM" list </dev/null 2>/dev/null )" ] && echo 1 || echo 0)" \
     "claims: evidence survives the commit that packages the same code"
( cd "$CID" && echo 'c' > src/f.ts ) >/dev/null 2>&1
ok_t "$([ -z "$( cd "$CID" && PROOFGATE_LIB="$LIB" bash "$CLAIM" list </dev/null 2>/dev/null )" ] && echo 1 || echo 0)" \
     "claims: evidence does NOT survive a real change to the code (negative)"
rm -rf "$CID"

echo "══ audit-hook: a chronology, never evidence ════════════════"
AU="$(mktemp -d)"
( cd "$AU" && git init -q -b main && git config user.email t@t && git config user.name t
  printf '{"audit":true}\n' > proofgate.json && git add -A && git commit -qm base ) >/dev/null 2>&1
( cd "$AU" && printf '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | bash "$ROOT/hooks/audit-hook.sh" ) >/dev/null 2>&1
ok_t "$([ -f "$AU/.git/proofgate-audit.jsonl" ] && echo 1 || echo 0)" "audit: audit:true → the command is recorded"
ok_t "$(grep -q '"exit":null' "$AU/.git/proofgate-audit.jsonl" 2>/dev/null && echo 1 || echo 0)"      "audit: exit is null — a PostToolUse hook cannot know it, and must not pretend"
( cd "$AU" && printf '{"audit":false}\n' > proofgate.json && rm -f .git/proofgate-audit.jsonl
  printf '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | bash "$ROOT/hooks/audit-hook.sh" ) >/dev/null 2>&1
ok_t "$([ -f "$AU/.git/proofgate-audit.jsonl" ] && echo 0 || echo 1)" "audit: off by default → nothing written (negative)"
ac=0; ( cd "$AU" && printf 'not json' | bash "$ROOT/hooks/audit-hook.sh" ) >/dev/null 2>&1 || ac=$?
ok_t "$([ "$ac" = 0 ] && echo 1 || echo 0)" "audit: malformed stdin → fail-open"
rm -rf "$AU"

echo "══ portability + docs (the promises we make about ourselves) ═"
# CI runs macOS: bash 3.2 and BSD userland. Every one of these constructs works on
# the dev box and fails there — which is the worst possible failure, because the
# author sees green. Catch them here instead of in a red matrix job.
BASH4=$(grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|sed -i |wait -n|date -d |readlink -f|grep -P|xargs -r|flock |EPOCHSECONDS|nproc' \
  "$ROOT"/skills/proofgate/scripts/*.sh "$ROOT"/skills/proofgate/scripts/guards.d/*.sh "$ROOT"/hooks/*.sh "$ROOT/install.sh" 2>/dev/null \
  | grep -v ':[0-9]*: *#' | grep -v 'proofgate-allow' || true)
if [ -z "$BASH4" ]; then echo "PASS  portability: no bash4/GNU-only constructs"; PASS=$((PASS + 1))
else echo "FAIL  portability: non-portable construct(s):"; printf '%s\n' "$BASH4" | sed 's/^/      /'; FAIL=$((FAIL + 1)); fi

# The guard count is written in five places and was already wrong once (docs said
# 18, guards.d held 19). Numbers a human maintains by hand drift; assert it.
GN=$(find "$GUARDS" -name '*.sh' | grep -c . || true)
DRIFT=$(grep -rlE "\b(1[0-9]|[2-9][0-9])[ ]?(diff )?guards" "$ROOT/README.md" "$ROOT/skills/proofgate/SKILL.md" "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json" "$ROOT/action.yml" 2>/dev/null \
  | while IFS= read -r f; do grep -oE "\b(1[0-9]|[2-9][0-9])[ ]?(diff )?guards" "$f" | grep -oE '^[0-9]+' | while IFS= read -r n; do [ "$n" = "$GN" ] || echo "$f says $n"; done; done)
if [ -z "$DRIFT" ]; then echo "PASS  docs: guard count matches guards.d ($GN)"; PASS=$((PASS + 1))
else echo "FAIL  docs: guard count drift (guards.d has $GN):"; printf '%s\n' "$DRIFT" | sed 's/^/      /'; FAIL=$((FAIL + 1)); fi

echo "═════════════════════════════════════════════════════════════"
echo "$PASS passed · $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
