#!/usr/bin/env bash
# ProofGate — the BLAST RADIUS of the change you are about to ship.
#
# Usage:
#   bash impact.sh                  # compute + write .git/proofgate-impact.json
#   bash impact.sh --json           # ...and print it on stdout
#   bash impact.sh --slice          # ...and write .git/proofgate-slice.md (skeptic scope)
#   bash impact.sh --base <ref>     # diff base (default: merge-base with origin default)
#   bash impact.sh --no-cache       # ignore the tree-hash cache
#
# WHY this exists, and why it is the FIRST thing the gate runs:
#
# A gate with one fixed price is a gate people turn off. Judging a README edit with
# the same ceremony as a migration to the payments table teaches everyone that the
# ceremony is noise. So the cost has to be proportional — and "proportional to what"
# has to be COMPUTED, not felt. That is this file: one measurement of what the diff
# can break, which then decides the level of evidence the delivery owes (verify.sh),
# what the skeptic reads (--slice), and which memory the change invalidates.
#
# Two design rules it never breaks:
#
#  1. The range is the WHOLE BRANCH plus the working tree — merge-base..HEAD *and*
#     uncommitted edits. Scoping to the last commit would make the risk class
#     trivially gameable: three commits, run the gate on the docs-only one, ship the
#     migration inside it. (The guards still read BASE..HEAD; the engine's
#     `git-committed` FAIL is what forces the two views to converge before a verdict.)
#
#  2. Every reduction in confidence is DECLARED. Without ctags there is no symbol
#     table, so callers come from a word-boundary grep and `navigation_confidence`
#     says `low`. A tool that quietly answers with less certainty than it implies is
#     the exact failure this whole project exists to stop — so the number of things
#     it could not do is a field in the output, not a silence.
#
# Backends, best first (each one declares itself in `navigation_backend`):
#   external  — config `impact.backendCmd`: reads changed paths on stdin, prints
#               `S<TAB>file<TAB>symbol<TAB>kind<TAB>line` and `C<TAB>symbol<TAB>file<TAB>line`.
#               This is the LSP seam: real go-to-definition is a JSON-RPC client, not
#               a bash script, so ProofGate does not pretend — it hands the job over.
#   ctags     — Universal Ctags: a real symbol table, confidence `high`.
#   grep      — hunk headers + declaration regex, confidence `low`. Always available.
set -uo pipefail

BASE_REF="" JSON=0 SLICE=0 NOCACHE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) shift; BASE_REF="${1:-}" ;;
    --json) JSON=1 ;;
    --slice) SLICE=1 ;;
    --no-cache) NOCACHE=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROOFGATE_CFG="${PROOFGATE_CFG:-proofgate.json}"
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$SCRIPT_DIR/lib.sh}" 2>/dev/null || true
command -v cfg >/dev/null 2>&1 || { echo "impact: lib.sh not found" >&2; exit 1; }

GD="$(pg_git_dir)"; CD="$(pg_common_dir)"
OUT="$GD/proofgate-impact.json"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

# ── base ─────────────────────────────────────────────────────────────────────
if [ -z "$BASE_REF" ]; then
  DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -z "$DEFAULT_BRANCH" ] && for b in main master; do git rev-parse "origin/$b" >/dev/null 2>&1 && { DEFAULT_BRANCH="$b"; break; }; done
  if [ -n "$DEFAULT_BRANCH" ]; then BASE_REF="$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || true)"; fi
  [ -z "$BASE_REF" ] && BASE_REF="$(git rev-parse HEAD~1 2>/dev/null || echo "$HEAD_SHA")"
fi
BASE_SHA="$(git rev-parse "$BASE_REF" 2>/dev/null || echo "$BASE_REF")"

# ── cache: same tree + same base ⇒ same answer ───────────────────────────────
TREE_HASH="$(pg_tree_hash)"
CACHE_KEY="$(printf '%s|%s|%s' "$TREE_HASH" "$BASE_SHA" "$(pg_sha1 "$PROOFGATE_CFG" 2>/dev/null)" | pg_sha1)"
CACHE_DIR="$CD/proofgate-cache"
CACHE_FILE="$CACHE_DIR/impact.$CACHE_KEY.json"
if [ "$NOCACHE" != 1 ] && [ -f "$CACHE_FILE" ] && [ "$SLICE" != 1 ]; then
  cp "$CACHE_FILE" "$OUT" 2>/dev/null
  [ "$JSON" = 1 ] && cat "$OUT"
  exit 0
fi

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT INT TERM
DEGR=""   # JSON objects, comma-joined
degrade() { DEGR="${DEGR:+$DEGR,}{\"code\":\"$1\",\"detail\":\"$(pg_json_escape "$2")\"}"; }

# ── changed files: committed range + working tree + untracked ────────────────
# `git diff BASE` (no ..HEAD) already spans commits AND the working tree.
{
  git diff --name-status "$BASE_SHA" -- . 2>/dev/null | awk -F'\t' '{ st=substr($1,1,1); print st "\t" $NF }'
  git ls-files -o --exclude-standard 2>/dev/null | awk '{ print "U\t" $0 }'
} | LC_ALL=C sort -u -t"$(printf '\t')" -k2,2 > "$TMPD/files.tsv"

SRC_GLOBS="$(cfg '.sourceGlobs')"; SRC_GLOBS="${SRC_GLOBS:-src/|lib/|app/}"
SENS_GLOBS="$(cfg '.sensitiveGlobs')"
SENS_GLOBS="${SENS_GLOBS:-(^|/)(auth|oauth|session|permission|acl|rbac|billing|payment|checkout|crypto|tls|ssl|cert|secret|migration)s?(/|[._-])}"
SENS_TERMS="$(cfg '.sensitiveTerms')"
SENS_TERMS="${SENS_TERMS:-\\b(is_admin|isAdmin|bearer|jwt|refund|charge|amount_cents|private key|rejectUnauthorized|verify=False|ALTER TABLE|DROP TABLE|GRANT )}"
TEST_RE='(\.test\.|\.spec\.|__tests__|_test\.|(^|/)tests?/)'
DOC_RE='\.(md|mdx|txt|rst|adoc)$|^(docs|LICENSE|CHANGELOG)'
CFG_RE='\.(json|ya?ml|toml|ini|cfg|lock|env\.example)$|^\.[a-z]'
CODE_RE='\.(ts|tsx|js|jsx|mjs|cjs|py|rb|go|rs|java|kt|swift|cs|php|ex|exs|scala|c|h|cpp|hpp|sh)$'

# ── classify + blob per file ─────────────────────────────────────────────────
FILES_JSON="" N_FILES=0 N_SRC=0 N_TEST=0 SENS_HITS=""
: > "$TMPD/source.txt"
while IFS="$(printf '\t')" read -r status path; do
  [ -n "$path" ] || continue
  case "$path" in .proofgate/*|*/.proofgate/*) klass="memory" ;; *)
    if   printf '%s' "$path" | grep -Eq "$TEST_RE"; then klass="test"
    elif printf '%s' "$path" | grep -Eq "$DOC_RE";  then klass="docs"
    elif printf '%s' "$path" | grep -Eq "$CODE_RE"; then klass="source"
    elif printf '%s' "$path" | grep -Eq "$CFG_RE";  then klass="config"
    else klass="other"; fi ;;
  esac
  if [ "$klass" = "source" ] && printf '%s' "$path" | grep -Eq "$SENS_GLOBS"; then
    klass="sensitive"; SENS_HITS="${SENS_HITS}path $path ~ sensitiveGlobs
"
  fi
  blob=""
  [ -f "$path" ] && blob="$(git hash-object -- "$path" 2>/dev/null)"
  FILES_JSON="${FILES_JSON:+$FILES_JSON,}{\"path\":\"$(pg_json_escape "$path")\",\"status\":\"$status\",\"class\":\"$klass\",\"blob\":\"$blob\"}"
  N_FILES=$((N_FILES + 1))
  case "$klass" in
    source|sensitive) N_SRC=$((N_SRC + 1)); [ -f "$path" ] && printf '%s\n' "$path" >> "$TMPD/source.txt" ;;
    test) N_TEST=$((N_TEST + 1)) ;;
  esac
done < "$TMPD/files.tsv"

# Sensitive by CONTENT, not just by path: logic that moves money or checks a
# permission is L3 wherever someone filed it. Three restrictions keep that from
# becoming noise, and the third was found by this gate judging its own diff:
#   - added lines only, and never in tests;
#   - TWO distinct term hits — one `bearer` in a comment is not a reason to demand
#     a security review of a typo fix;
#   - only SOURCE files. A term list is documentation in a README, a config example
#     or a changelog, and scanning those flagged this very release as L3 for the
#     crime of describing what L3 means.
if [ -s "$TMPD/source.txt" ]; then
  # shellcheck disable=SC2046  # deliberate: the changed source paths become a pathspec list
  TERM_HITS="$(git diff "$BASE_SHA" -- $(tr '\n' ' ' < "$TMPD/source.txt") "${PG_SELF_EXCLUDE[@]}" 2>/dev/null \
    | grep -E '^\+' | grep -v '^+++' | grep -v 'proofgate-allow' \
    | grep -Eio -- "$SENS_TERMS" 2>/dev/null \
    | tr 'A-Z' 'a-z' | LC_ALL=C sort -u)"
  TERM_N="$(printf '%s' "$TERM_HITS" | pg_count)"
  if [ "${TERM_N:-0}" -ge 2 ]; then
    SENS_HITS="${SENS_HITS}added lines match sensitiveTerms: $(printf '%s' "$TERM_HITS" | tr '\n' ' ')
"
  fi
fi

# ── symbols (backend tiers) ──────────────────────────────────────────────────
BACKEND="grep" CONF="low"
BACKEND_CMD="$(cfg '.impact.backendCmd')"
: > "$TMPD/symbols.tsv"     # file \t symbol \t kind \t line
: > "$TMPD/callers.tsv"     # symbol \t file \t line

if [ -n "$BACKEND_CMD" ] && [ -s "$TMPD/source.txt" ]; then
  bash -c "$BACKEND_CMD" < "$TMPD/source.txt" > "$TMPD/backend.out" 2>/dev/null || true
  awk -F'\t' '$1=="S"{print $2 "\t" $3 "\t" $4 "\t" ($5 == "" ? 0 : $5)}' "$TMPD/backend.out" > "$TMPD/symbols.tsv"
  awk -F'\t' '$1=="C"{print $2 "\t" $3 "\t" ($4 == "" ? 0 : $4)}' "$TMPD/backend.out" > "$TMPD/callers.tsv"
  if [ -s "$TMPD/symbols.tsv" ]; then
    BACKEND="external:$(printf '%s' "$BACKEND_CMD" | awk '{print $1}' | sed 's|.*/||')"; CONF="high"
  else
    degrade "backend-empty" "impact.backendCmd produced no symbols — fell back to the built-in backends"
  fi
fi

if [ "$CONF" = "low" ] && [ -s "$TMPD/source.txt" ] && command -v ctags >/dev/null 2>&1 \
   && ctags --version 2>/dev/null | grep -qi universal; then
  # Universal Ctags gives a real symbol table. Intersect it with the CHANGED line
  # ranges, so a 900-symbol file whose one edited function is `parsePrice` reports
  # `parsePrice` — not 900 symbols and a useless caller sweep.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    git diff -U0 "$BASE_SHA" -- "$f" 2>/dev/null \
      | awk '/^@@/ { if (match($0, /\+[0-9]+(,[0-9]+)?/)) { s = substr($0, RSTART+1, RLENGTH-1); n = 1; if (index(s, ",")) { n = substr(s, index(s, ",")+1); s = substr(s, 1, index(s, ",")-1) } print s "\t" (s + n) } }' \
      > "$TMPD/ranges.tsv"
    [ -s "$TMPD/ranges.tsv" ] || continue
    ctags -x --sort=no --_xformat='%N	%K	%n' -f - "$f" 2>/dev/null \
      | awk -F'\t' -v file="$f" -v rf="$TMPD/ranges.tsv" '
          BEGIN { while ((getline r < rf) > 0) { split(r, a, "\t"); lo[++k] = a[1]; hi[k] = a[2] } }
          { for (i = 1; i <= k; i++) if ($3 + 0 >= lo[i] - 3 && $3 + 0 <= hi[i] + 3) { print file "\t" $1 "\t" $2 "\t" $3; break } }' \
      >> "$TMPD/symbols.tsv"
  done < "$TMPD/source.txt"
  if [ -s "$TMPD/symbols.tsv" ]; then BACKEND="ctags"; CONF="high"; fi
fi

if [ ! -s "$TMPD/symbols.tsv" ] && [ -s "$TMPD/source.txt" ]; then
  # No symbol table. `git diff -U0` hunk headers carry the enclosing function on
  # most languages, and added/removed declaration lines carry the rest.
  BACKEND="grep"; CONF="low"
  if ! command -v ctags >/dev/null 2>&1; then
    degrade "no-ctags" "Universal Ctags not on PATH — symbols come from a regex, callers from a word-boundary grep"
  elif ! ctags --version 2>/dev/null | grep -qi universal; then
    # macOS ships Exuberant/BSD ctags, whose output format this does not parse.
    degrade "no-ctags" "ctags is present but not Universal Ctags — symbols come from a regex, callers from a word-boundary grep"
  fi
  while IFS= read -r f; do
    git diff -U0 "$BASE_SHA" -- "$f" 2>/dev/null | awk -F'\n' -v file="$f" '
      /^@@/ {
        ln = 0; if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART+1, RLENGTH-1) + 0
        tail = $0; sub(/^@@[^@]*@@[[:space:]]*/, "", tail)
        if (match(tail, /[A-Za-z_][A-Za-z0-9_]{2,}/)) print file "\t" substr(tail, RSTART, RLENGTH) "\thunk\t" ln
        next
      }
      /^[+-]/ && !/^(\+\+\+|---)/ {
        line = substr($0, 2)
        if (match(line, /(function|def|class|fn|func|const|let|var|type|interface|struct|enum|trait|impl|module|sub|public|private|protected)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
          seg = substr(line, RSTART, RLENGTH)
          if (match(seg, /[A-Za-z_][A-Za-z0-9_]*$/)) print file "\t" substr(seg, RSTART, RLENGTH) "\tdecl\t0"
        }
      }' >> "$TMPD/symbols.tsv"
  done < "$TMPD/source.txt"
fi

# Stopwords: grepping the repo for `data` or `value` finds every file and proves
# nothing. Short and generic names are dropped BEFORE the caller sweep.
STOP='^(if|for|the|and|not|new|get|set|out|end|run|add|use|let|var|const|type|class|func|function|def|main|data|item|value|result|error|test|name|path|file|line|true|false|null|none|self|this|args|kwargs|return|import|export|from|async|await|public|private|protected|static|void|int|str|bool|list|dict|map|obj)$'
awk -F'\t' '{print $2}' "$TMPD/symbols.tsv" 2>/dev/null \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]{2,}$' \
  | grep -Eiv "$STOP" | LC_ALL=C sort -u > "$TMPD/syms.txt"

MAXSYM="$(cfg '.impact.maxSymbols')"; MAXSYM="${MAXSYM:-100}"
MAXCALL="$(cfg '.impact.maxCallers')"; MAXCALL="${MAXCALL:-500}"
SYM_TOTAL="$(pg_lines "$TMPD/syms.txt")"
if [ "${SYM_TOTAL:-0}" -gt "$MAXSYM" ]; then
  head -"$MAXSYM" "$TMPD/syms.txt" > "$TMPD/syms.cap" && mv "$TMPD/syms.cap" "$TMPD/syms.txt"
  degrade "symbols-truncated" "$SYM_TOTAL symbols found, capped at $MAXSYM (impact.maxSymbols)"
fi

# ── callers: ONE batched git grep, never one per symbol ──────────────────────
# On a monorepo a per-symbol grep is N full scans. git grep is index-backed and
# takes an alternation, so the whole sweep is a single pass that excludes the
# changed files themselves (a definition is not a caller).
if [ ! -s "$TMPD/callers.tsv" ] && [ -s "$TMPD/syms.txt" ]; then
  ALT="$(tr '\n' '|' < "$TMPD/syms.txt" | sed 's/|$//')"
  EXCL=""
  while IFS= read -r f; do EXCL="$EXCL :(exclude)$f"; done < "$TMPD/source.txt"
  # shellcheck disable=SC2086
  git grep -n -I -w -E -e "$ALT" -- . $EXCL "${PG_SELF_EXCLUDE[@]}" 2>/dev/null \
    | grep -Ev "$TEST_RE" \
    | awk -F':' -v alt="$ALT" '
        BEGIN { n = split(alt, syms, "|") }
        { file = $1; line = $2; rest = $0
          for (i = 1; i <= n; i++) if (index(rest, syms[i])) { print syms[i] "\t" file "\t" line; break } }' \
    | head -"$MAXCALL" > "$TMPD/callers.tsv"
  CALL_RAW="$(pg_lines "$TMPD/callers.tsv")"
  [ "${CALL_RAW:-0}" -ge "$MAXCALL" ] && degrade "callers-truncated" "caller list capped at $MAXCALL (impact.maxCallers)"
fi

# ── affected tests: naming convention ∪ tests that name a changed symbol ─────
{
  while IFS= read -r f; do
    stem="$(printf '%s' "$f" | sed -E 's/\.[^.\/]+$//')"
    base="$(basename "$stem")"
    git ls-files 2>/dev/null | grep -E "$TEST_RE" | grep -E "(^|/)(${base}|test_${base})[._]" || true
  done < "$TMPD/source.txt"
  if [ -s "$TMPD/syms.txt" ]; then
    ALT2="$(tr '\n' '|' < "$TMPD/syms.txt" | sed 's/|$//')"
    git grep -l -I -w -E -e "$ALT2" -- . "${PG_SELF_EXCLUDE[@]}" 2>/dev/null | grep -E "$TEST_RE" || true
  fi
} 2>/dev/null | LC_ALL=C sort -u | head -100 > "$TMPD/tests.txt"

# ── importers (depth 1). Real module resolution per language is out of scope for
# a shell script, so this is declared as depth-1 rather than sold as a closure. ──
if [ -s "$TMPD/source.txt" ]; then
  : > "$TMPD/importers.txt"
  while IFS= read -r f; do
    stem="$(basename "$f" | sed -E 's/\.[^.]+$//')"
    [ ${#stem} -ge 3 ] || continue
    git grep -l -I -E -e "(from|require|import|use|include)[^;]*['\"/]${stem}['\"]" -- . "${PG_SELF_EXCLUDE[@]}" 2>/dev/null || true
  done < "$TMPD/source.txt" | LC_ALL=C sort -u | head -100 > "$TMPD/importers.txt"
  [ -s "$TMPD/importers.txt" ] && degrade "closure-depth-1" "importers are direct only; a transitive closure needs real module resolution (impact.backendCmd)"
fi

# ── risk class ───────────────────────────────────────────────────────────────
N_CALLERS="$(pg_lines "$TMPD/callers.tsv")"
N_SYMS="$(pg_lines "$TMPD/syms.txt")"
N_TESTS="$(pg_lines "$TMPD/tests.txt")"

RISK="L1"
[ "${N_SRC:-0}" -gt 0 ] && RISK="L2"
if [ -n "$SENS_HITS" ]; then RISK="L3"; fi

# An open, ESCALATED hypothesis inverts the bar (SKILL § external causes): the same
# symptom has already survived two explanations, so the next one is not trusted on
# its own. Written by hypothesis.sh (2.9); absent before that, and absent in repos
# that never open one — hence the plain file test.
ESCALATED=""
HYP="$GD/proofgate-hypotheses.jsonl"
if [ -f "$HYP" ]; then
  ESCALATED="$(grep '"escalated":true' "$HYP" 2>/dev/null | tail -1 | grep -o '"symptom":"[^"]*"' | sed -e 's/^"symptom":"//' -e 's/"$//')"
fi

SKEPTIC_REQ=false
[ "$RISK" = "L3" ] && SKEPTIC_REQ=true
[ -n "$ESCALATED" ] && { SKEPTIC_REQ=true; SENS_HITS="${SENS_HITS}strike escalation: symptom '$ESCALATED' already refuted twice — bar inverted
"; }

REQUIRED="E1"
[ "$RISK" = "L1" ] || REQUIRED="E3"

# ── what level is even REACHABLE here? ───────────────────────────────────────
# E3 means the real flow was driven on a real runtime. On a box with no way to
# drive one, demanding E3 would fail every delivery for a reason the author cannot
# fix — so instead the engine reports `cannot_prove` and NAMES the missing
# capability. Missing evidence and impossible evidence are different verdicts.
DRIVER="null"
if   [ -n "$(cfg '.commands.e2e')" ]; then DRIVER="commands.e2e"
elif [ "$(cfg_len '.smoke')" != "0" ] && [ -n "$(cfg_len '.smoke')" ]; then DRIVER="smoke"
elif [ -f package.json ] && grep -Eq '"(playwright|cypress|puppeteer|@playwright/test|selenium-webdriver)"' package.json 2>/dev/null; then DRIVER="e2e-dependency"
elif command -v curl >/dev/null 2>&1 && [ -f package.json ] && grep -Eq '"(dev|start|serve)"[[:space:]]*:' package.json 2>/dev/null; then DRIVER="curl+devserver"
fi
MAXLEVEL="E3"
if [ "$DRIVER" = "null" ]; then
  MAXLEVEL="E2"
  degrade "no-runtime-driver" "no e2e command, smoke[] or dev server + curl — E3 cannot be produced on this machine"
fi
[ "$(cfg_len '.smoke')" != "0" ] && [ -n "$(cfg_len '.smoke')" ] && MAXLEVEL="E4"

REASONS=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  REASONS="${REASONS:+$REASONS,}\"$(pg_json_escape "$r")\""
done <<EOF
$SENS_HITS
EOF

# ── emit ─────────────────────────────────────────────────────────────────────
# Single line, fixed key order, NO nested key literally named "sha" or "pass":
# the hooks read this family of files with grep, and a second match would silently
# win. Nested shas are always head_sha / base_sha.
SYMS_JSON="$(awk -F'\t' 'NF>=3 { printf "%s{\"file\":\"%s\",\"name\":\"%s\",\"kind\":\"%s\",\"line\":%d}", (n++ ? "," : ""), $1, $2, $3, $4 }' "$TMPD/symbols.tsv" 2>/dev/null)"
CALL_JSON="$(awk -F'\t' 'NF>=3 { printf "%s{\"symbol\":\"%s\",\"file\":\"%s\",\"line\":%d}", (n++ ? "," : ""), $1, $2, $3 }' "$TMPD/callers.tsv" 2>/dev/null)"
TESTS_JSON="$(awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }' "$TMPD/tests.txt" 2>/dev/null)"
IMP_JSON="$(awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }' "$TMPD/importers.txt" 2>/dev/null)"

IMPACT="{\"schemaVersion\":1,\"head_sha\":\"$HEAD_SHA\",\"base_sha\":\"$BASE_SHA\",\"tree_hash\":\"$TREE_HASH\",\"generatedAt\":\"$(pg_now)\""
IMPACT="$IMPACT,\"risk_class\":\"$RISK\",\"risk_reasons\":[$REASONS]"
IMPACT="$IMPACT,\"required_level\":\"$REQUIRED\",\"skeptic_required\":$SKEPTIC_REQ"
IMPACT="$IMPACT,\"navigation_backend\":\"$BACKEND\",\"navigation_confidence\":\"$CONF\""
IMPACT="$IMPACT,\"capabilities\":{\"runtime_driver\":\"$DRIVER\"},\"max_achievable_level\":\"$MAXLEVEL\""
IMPACT="$IMPACT,\"degradations\":[$DEGR]"
# Count keys are deliberately unique across the whole document (files_n, not
# files): these files are read back with a first-match grep, and a bare "files"
# would collide with the files[] array below — the same greedy-match class of bug
# that makes the verdict contract require exactly one "sha".
IMPACT="$IMPACT,\"counts\":{\"files_n\":$N_FILES,\"source_n\":$N_SRC,\"tests_changed_n\":$N_TEST,\"symbols_n\":${N_SYMS:-0},\"callers_n\":${N_CALLERS:-0},\"affected_tests_n\":${N_TESTS:-0}}"
IMPACT="$IMPACT,\"files\":[$FILES_JSON],\"symbols\":[$SYMS_JSON],\"callers\":[$CALL_JSON]"
IMPACT="$IMPACT,\"affected_tests\":[$TESTS_JSON],\"importers\":[${IMP_JSON:-}]}"

mkdir -p "$CACHE_DIR" 2>/dev/null
TMPV="$(mktemp "$GD/.proofgate-impact.XXXXXX" 2>/dev/null || mktemp)"
printf '%s\n' "$IMPACT" > "$TMPV" && mv "$TMPV" "$OUT"
cp "$OUT" "$CACHE_FILE" 2>/dev/null || true
# Keep the cache from growing without bound (only this repo's own entries).
ls -t "$CACHE_DIR"/impact.*.json 2>/dev/null | tail -n +21 | while IFS= read -r old; do rm -f "$old"; done

# ── --slice: the skeptic's reading scope ─────────────────────────────────────
# A skeptic handed the whole repository reads none of it; a skeptic handed the
# author's prose audits the prose. It gets the diff plus the first-degree callers.
if [ "$SLICE" = 1 ]; then
  SLICE_F="$GD/proofgate-slice.md"
  {
    echo "# ProofGate slice — HEAD ${HEAD_SHA:0:7} vs ${BASE_SHA:0:7}"
    echo
    echo "risk_class: $RISK · required_level: $REQUIRED · max_achievable: $MAXLEVEL"
    echo "navigation: $BACKEND ($CONF confidence)"
    [ -n "$SENS_HITS" ] && { echo; echo "## why this is $RISK"; printf '%s' "$SENS_HITS" | sed 's/^/- /'; }
    echo; echo "## the diff"; echo '```diff'
    git diff "$BASE_SHA" -- . 2>/dev/null | head -2000
    echo '```'
    if [ -s "$TMPD/callers.tsv" ]; then
      echo; echo "## first-degree callers (context ±3)"
      awk -F'\t' '{print $2 "\t" $3}' "$TMPD/callers.tsv" | LC_ALL=C sort -u | head -25 | while IFS="$(printf '\t')" read -r cf cl; do
        [ -f "$cf" ] || continue
        echo; echo "### $cf:$cl"; echo '```'
        awk -v n="$cl" 'NR >= n-3 && NR <= n+3 { printf "%d: %s\n", NR, $0 }' "$cf"
        echo '```'
      done
    fi
    if [ -s "$TMPD/tests.txt" ]; then echo; echo "## tests that touch these symbols"; sed 's/^/- /' "$TMPD/tests.txt"; fi
  } > "$SLICE_F" 2>/dev/null
fi

[ "$JSON" = 1 ] && printf '%s\n' "$IMPACT"
exit 0
