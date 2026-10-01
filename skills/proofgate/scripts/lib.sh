#!/usr/bin/env bash
# ProofGate shared library — sourced by verify.sh AND by any guard that needs to
# read proofgate.json. The whole point: config access with ZERO hard dependency.
# jq is preferred; when it is absent we fall back to node, then python3; when none
# of the three exists every function degrades to "empty" and the caller keeps its
# own inline default. Nothing here ever hard-fails a gate.
#
# Contract for callers: export/point PROOFGATE_CFG at proofgate.json before use
# (defaults to ./proofgate.json). All functions are safe to call when the file is
# absent — they simply return nothing.
#
# Scars this file carries:
#  - v1 made jq a hard dependency for ALL config and silently ignored proofgate.json
#    on any machine without jq. That is exactly the "works on my box" trap the gate
#    exists to kill, so the gate's own config reader must not have it.

# shellcheck disable=SC2120  # helpers are intentionally callable with no args

_pg_cfg_file() { printf '%s' "${PROOFGATE_CFG:-proofgate.json}"; }

# The node/python walkers parse a RESTRICTED jq path grammar: dotted keys plus
# [N] integer indices (e.g. .commands.typecheck, .smoke[0].url). That is all any
# guard needs; anything fancier should use jq (and degrade to empty without it).
_PG_NODE_WALK='const fs=require("fs");try{const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const p=String(process.argv[2]).replace(/^\./,"");let c=d;if(p!==""){for(const seg of p.split(".")){const m=seg.match(/^([^\[]*)(?:\[(\d+)\])?$/);if(!m)process.exit(0);if(m[1]!==""){if(c==null)process.exit(0);c=c[m[1].replace(/^"|"$/g,"")];}if(m[2]!==undefined){if(c==null)process.exit(0);c=c[Number(m[2])];}}}if(c==null)process.exit(0);process.stdout.write(typeof c==="object"?JSON.stringify(c):String(c));}catch(e){process.exit(0);}'
_PG_PY_WALK='import sys,json,re
try:
 d=json.load(open(sys.argv[1]));p=sys.argv[2]
 if p[:1]==".":p=p[1:]
 c=d
 if p!="":
  for seg in p.split("."):
   m=re.match(r"^([^\[]*)(?:\[(\d+)\])?$",seg)
   if not m:sys.exit(0)
   k,i=m.group(1),m.group(2)
   if k and k[:1]==chr(34) and k[-1:]==chr(34):k=k[1:-1]
   if k!="":
    if c is None:sys.exit(0)
    c=c.get(k) if isinstance(c,dict) else None
   if i is not None:
    if not isinstance(c,list) or int(i)>=len(c):sys.exit(0)
    c=c[int(i)]
 if c is None:sys.exit(0)
 sys.stdout.write(c if isinstance(c,str) else (json.dumps(c) if isinstance(c,(dict,list)) else ("true" if c is True else "false" if c is False else str(c))))
except Exception:
 sys.exit(0)'

# cfg <jq-path> — print a scalar raw, or a compact JSON string for objects/arrays.
# Empty output when the key is missing, the file is absent, or no parser exists.
cfg() {
  local path="$1" f; f="$(_pg_cfg_file)"
  [ -f "$f" ] || return 0
  if command -v jq >/dev/null 2>&1; then jq -c -r "$path // empty" "$f" 2>/dev/null; return; fi
  if command -v node >/dev/null 2>&1; then node -e "$_PG_NODE_WALK" "$f" "$path" 2>/dev/null; return; fi
  command -v python3 >/dev/null 2>&1 && python3 -c "$_PG_PY_WALK" "$f" "$path" 2>/dev/null
}

# cfg_len <jq-path-to-array> — element count (0 when absent/not an array).
cfg_len() {
  local j; j="$(cfg "$1")"
  [ -z "$j" ] && { printf '0'; return; }
  if command -v jq >/dev/null 2>&1; then printf '%s' "$j" | jq 'if type=="array" then length else 0 end' 2>/dev/null || printf '0'; return; fi
  if command -v node >/dev/null 2>&1; then printf '%s' "$j" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);process.stdout.write(String(Array.isArray(a)?a.length:0));}catch(e){process.stdout.write("0");}})' 2>/dev/null || printf '0'; return; fi
  printf '%s' "$j" | python3 -c 'import sys,json
try:
 a=json.load(sys.stdin);print(len(a) if isinstance(a,list) else 0)
except Exception:print(0)' 2>/dev/null || printf '0'
}

# cfg_list <jq-path-to-array> — one scalar per line (objects printed as compact JSON).
cfg_list() {
  local j; j="$(cfg "$1")"
  [ -z "$j" ] && return 0
  if command -v jq >/dev/null 2>&1; then printf '%s' "$j" | jq -r 'if type=="array" then .[] else empty end | if type=="object" or type=="array" then tojson else . end' 2>/dev/null; return; fi
  if command -v node >/dev/null 2>&1; then printf '%s' "$j" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);(Array.isArray(a)?a:[]).forEach(x=>console.log(x!==null&&typeof x==="object"?JSON.stringify(x):String(x)));}catch(e){}})' 2>/dev/null; return; fi
  printf '%s' "$j" | python3 -c 'import sys,json
try:
 a=json.load(sys.stdin)
 for x in (a if isinstance(a,list) else []):
  print(json.dumps(x) if isinstance(x,(dict,list)) else x)
except Exception:pass' 2>/dev/null
}

# pg_json_escape <string> — escape a string for embedding in JSON (backslash FIRST).
# Used by verify.sh to hand-write the verdict and by guards that record detail.
pg_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# pg_json_field <json-line> <jq-path> — read a value back out of a stored JSON line,
# CORRECTLY unescaped, using the same jq → node → python3 chain as the config reader.
#
# The scar, found while testing `proof.sh replay`: it pulled the recorded command out of
# the note with grep and ran it as-is. The ledger stores `printf 'calc=3\n'` escaped, so
# what ran was a different command from the one being checked — the worst possible defect
# in the component whose entire job is confirming that recorded evidence still reproduces.
# It can fail honest evidence and it can pass evidence that no longer holds.
#
# The obvious fix — a few global replaces reversing pg_json_escape — is wrong, and wrong
# in a way that looks right: sequential substitution cannot invert an escape, because
# `\\n` (an escaped backslash then an 'n') matches the newline rule first. Undoing an
# escape needs a single left-to-right scan, which is what a real parser does.
# Anything READ BACK TO BE EXECUTED must go through here, never through grep.
pg_json_field() {
  local line="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$line" | jq -r "$path // empty" 2>/dev/null; return
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$line" | PG_PATH="$path" python3 -c 'import sys,json,os,re
try:
 d=json.load(sys.stdin); p=os.environ["PG_PATH"].lstrip(".")
 c=d
 for seg in p.split("."):
  m=re.match(r"^([^\[]*)(?:\[(\d+)\])?$",seg)
  if not m: sys.exit(0)
  k,i=m.group(1),m.group(2)
  if k:
   if not isinstance(c,dict): sys.exit(0)
   c=c.get(k)
  if i is not None:
   if not isinstance(c,list) or int(i)>=len(c): sys.exit(0)
   c=c[int(i)]
 if c is None: sys.exit(0)
 sys.stdout.write(c if isinstance(c,str) else json.dumps(c))
except Exception: sys.exit(0)' 2>/dev/null
    return
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$line" | PG_PATH="$path" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{let c=JSON.parse(s);for(const seg of process.env.PG_PATH.replace(/^\./,"").split(".")){const m=seg.match(/^([^\[]*)(?:\[(\d+)\])?$/);if(!m)return;if(m[1]){if(c==null)return;c=c[m[1]];}if(m[2]!==undefined){if(c==null)return;c=c[Number(m[2])];}}if(c==null)return;process.stdout.write(typeof c==="string"?c:JSON.stringify(c));}catch(e){}})' 2>/dev/null
    return
  fi
  # No parser at all: refuse rather than return a half-unescaped command to execute.
  return 0
}

# pg_fingerprint <guard> <file> <line-content> — stable id for suppression.
# Deliberately NOT the line NUMBER (churn-stable): guard name + path + a hash of
# the offending line's text. Mirrors gitleaks' fingerprint idea. Used by
# .proofgateignore, the persistent per-finding false-positive escape hatch.
pg_fingerprint() {
  local guard="$1" file="$2" content="$3" h
  if command -v sha1sum >/dev/null 2>&1; then h="$(printf '%s' "$content" | sha1sum | cut -c1-12)"
  elif command -v shasum >/dev/null 2>&1; then h="$(printf '%s' "$content" | shasum | cut -c1-12)"
  else h="$(printf '%s' "$content" | cksum | tr -d ' ' | cut -c1-12)"; fi
  printf '%s:%s:%s' "$guard" "$file" "$h"
}

# pg_ignored <fingerprint> — is this finding suppressed in .proofgateignore?
# The gate is DIFF-SCOPED (only $BASE..HEAD added lines), so legacy findings never
# pile up the way a full-repo scanner's do — a full baseline/ratchet would be
# over-engineering. What's still needed is a durable escape hatch for a specific
# false positive you can't annotate inline (e.g. a generated file): one fingerprint
# per line in .proofgateignore at the repo root ('#' comments allowed).
pg_ignored() {
  local fp="$1" f="${PROOFGATE_IGNORE:-.proofgateignore}"
  [ -f "$f" ] || return 1
  grep -Fxq -- "$fp" "$f" 2>/dev/null
}

# Pathspecs that keep the gate from flagging its OWN source. A directory pathspec where
# one is safe, individual names only where it is not: this list was a hand-maintained
# enumeration of every script, which meant adding a script silently meant forgetting to
# add it here — the same drift the guard-count test exists to catch, in the file whose
# job is preventing self-inflicted findings. Vendoring the guards
# into a consumer repo adds files whose text literally CONTAINS the sin patterns
# (rejectUnauthorized:false, <<<<<<<, key regexes); without this every guard would
# fail the very commit that installs it. (Guards also carry inline `proofgate-allow`
# on their pattern lines; this covers whole-file cases like the tests.)
# `.proofgateignore` is ProofGate's own control file: every line in it NAMES a
# finding, and its comments explain which pattern was suppressed and why. Scanning
# it made suppressing a finding create a new one in the suppression file — found by
# this gate on its own 2.7.0 diff. Safe for consumers too: the file is always ours.
PG_SELF_EXCLUDE=(
  ':(exclude).proofgateignore'                     # our own suppression list, which must NAME the patterns it suppresses
  ':(exclude)*guards.d/*'                          # every guard literally contains the sin it hunts
  # Both spellings: a leading `*/` requires a directory BEFORE it, so it misses the path
  # `skills/proofgate/scripts/...` at the repo root — which is this repo's own layout, so
  # the engine went straight back to flagging itself. Verified by the self-gate.
  ':(exclude)skills/proofgate/scripts/*' ':(exclude)*/skills/proofgate/scripts/*'
  ':(exclude)*/.proofgate/*' ':(exclude).proofgate/*'   # the vendored copy + the team's memory
  ':(exclude)*run-tests.sh' ':(exclude)*acceptance.sh'  # the tests, which plant sins on purpose
  # Hooks are named individually rather than by directory: `hooks/` is OUR path here, but
  # in a consumer repo it may hold their real code, and blanket-excluding it would blind
  # the gate on exactly the files they care about.
  ':(exclude)*push-guard.sh' ':(exclude)*stop-guard.sh' ':(exclude)*edit-guard.sh'
  ':(exclude)*session-hook.sh' ':(exclude)*edit-notice.sh' ':(exclude)*prompt-hook.sh'
  ':(exclude)*audit-hook.sh'
)

# pg_added_with_file [extra-pathspecs...] — stream "<file>\t<added-line>" for every
# added line in $BASE..HEAD, minus the gate's own files and any line bearing the
# `proofgate-allow` marker. The bedrock every diff guard builds on.
# LIVE mode (PROOFGATE_WORKTREE=1) points the same machinery at the WORKING TREE and,
# with PROOFGATE_PATHSPEC, at a single file — so the edit-notice hook can run the guards
# on a file the moment it is written, before it is committed. Defaults are unchanged:
# without those variables this is byte-for-byte the old behaviour.
#
# Coverage is partial in live mode and that is deliberate rather than hidden: guards
# that call `git diff "$BASE"..HEAD` themselves instead of using this helper see an
# empty range and stay quiet. They are not wrong, just not early — the gate still runs
# every one of them on the real diff. Silence here means "nothing this path can see",
# never "clean".
pg_added_with_file() {
  local base="${PROOFGATE_BASE:?PROOFGATE_BASE unset}"
  local range_diff
  if [ "${PROOFGATE_WORKTREE:-}" = 1 ]; then
    set -- "$@" ${PROOFGATE_PATHSPEC:+"$PROOFGATE_PATHSPEC"}
    range_diff="$(git diff HEAD -- . "${PG_SELF_EXCLUDE[@]}" "$@" 2>/dev/null)"
  else
    range_diff="$(git diff "$base"..HEAD -- . "${PG_SELF_EXCLUDE[@]}" "$@" 2>/dev/null)"
  fi
  printf '%s\n' "$range_diff" | awk '
    /^\+\+\+ b\// { f=substr($0,7); next }
    /^\+/ && !/^\+\+\+/ { l=substr($0,2); if (l !~ /proofgate-allow/) print f "\t" l }
  '
}

# pg_added_lines [pathspecs...] — every ADDED line in the guarded range, minus the
# gate's own files and any `proofgate-allow` line. The same view pg_added_with_file
# builds, without the filename prefix — several guards had hand-rolled this identical
# pipeline, which meant they also silently opted out of live mode.
pg_added_lines() {
  local base="${PROOFGATE_BASE:?PROOFGATE_BASE unset}"
  if [ "${PROOFGATE_WORKTREE:-}" = 1 ]; then
    set -- "$@" ${PROOFGATE_PATHSPEC:+"$PROOFGATE_PATHSPEC"}
    git diff HEAD -- "$@" "${PG_SELF_EXCLUDE[@]}" 2>/dev/null
  else
    git diff "$base"..HEAD -- "$@" "${PG_SELF_EXCLUDE[@]}" 2>/dev/null
  fi | grep -E '^\+' | grep -v '^+++' | grep -v 'proofgate-allow' || true
}

# pg_match <ERE> [-i] — keep the "<file>\t<line>" records whose CONTENT matches,
# using ONE grep for the whole stream instead of one grep per line.
#
# THE SCAR, measured: on a branch with 31.182 added lines, every diff guard spawned
# two processes per line and the gate took eight minutes — over a million forks for
# a run whose actual work is a handful of regex matches. Guards were being charged
# for process startup, not for scanning.
#
# Why not do the matching inside awk, which would need no temp file: the guards'
# patterns are GNU grep EREs and several use `\b`, which POSIX awk does not know and
# mawk does not support at all. Translating them would change what a guard matches —
# and a guard that quietly stops matching is worse than a slow one. So the ERE stays
# in grep, exactly as written, and only the CONTENT column is fed to it; the line
# numbers come back and rejoin with the file column, which keeps the "match content,
# never the path" rule that the per-line loop existed to enforce.
pg_match() {
  local pat="$1" ci="${2:-}"
  local tmp; tmp="$(pg_tmpfile pgmatch)"
  cat > "$tmp"
  # `cut -f2-` keeps everything after the FIRST tab: a diff line may contain tabs
  # of its own, and splitting on all of them would truncate the content.
  if [ "$ci" = "-i" ]; then
    cut -f2- "$tmp" | grep -niE -- "$pat" 2>/dev/null | cut -d: -f1 || true
  else
    cut -f2- "$tmp" | grep -nE -- "$pat" 2>/dev/null | cut -d: -f1 || true
  fi | awk 'NR==FNR { keep[$1]; next } FNR in keep' - "$tmp"
  rm -f "$tmp"
}

# pg_tmpfile <tag> — a temp file that gets cleaned up even if the guard dies.
pg_tmpfile() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/proofgate-$1.XXXXXX" 2>/dev/null)" || f="${TMPDIR:-/tmp}/proofgate-$1.$$"
  printf '%s' "$f"
}

# pg_scan <guard-name> <ERE> [extra-pathspecs...] — print the file of each added
# line matching the pattern, after self-exclusion, proofgate-allow, AND per-finding
# .proofgateignore suppression. Guards reduce to: count the lines this prints.
pg_scan() {
  local guard="$1" pat="$2"; shift 2
  local tab; tab="$(printf '\t')"
  # The fingerprint/suppression pass stays per line — but it now runs only for the
  # lines that MATCHED, which is a handful, instead of for every added line.
  pg_added_with_file "$@" | pg_match "$pat" | while IFS="$tab" read -r file content; do
    # A suppressed finding is data, not silence: it is one half of the ratio that says
    # whether this guard is still earning its place.
    if pg_ignored "$(pg_fingerprint "$guard" "$file" "$content")"; then
      pg_calib "$guard" allowed "$file (.proofgateignore)"
      continue
    fi
    printf '%s\n' "$file"
  done
}

# pg_count — count non-empty lines on stdin (the surviving findings from pg_scan).
# NOTE: `grep -c` prints 0 AND exits 1 on no match, so we capture its stdout rather
# than relying on exit status (a naive `grep -c . || echo 0` prints "0\n0").
pg_count() { local n; n="$(grep -c . 2>/dev/null)"; printf '%s' "${n:-0}"; }

# ── 3.0 helpers: hashing, JSON reading, git dirs, ledgers ─────────────────────
# Everything below is bash 3.2 + BSD safe (CI runs macOS): no associative arrays,
# no mapfile, no `sed -i`, no `date -d`, no sha1sum/shasum branching.

# pg_sha1 [file] — content hash via git's own hasher, present wherever git is.
# One code path on every platform (sha1sum/shasum/md5 differ in name AND output),
# and the value is a real blob id, so anchors can be compared against `git ls-files -s`.
# NOTE: pg_fingerprint deliberately does NOT use this — its hashes are already
# baked into users' .proofgateignore files, and changing them would silently
# un-suppress every existing exception.
# Called WITH a path that does not exist it prints nothing — it must never fall
# through to reading stdin, which would hang the caller waiting on a terminal.
pg_sha1() {
  if [ $# -gt 0 ]; then [ -f "$1" ] && git hash-object -- "$1" 2>/dev/null; return 0; fi
  git hash-object --stdin 2>/dev/null
}

# pg_lines <file> — line count that is 0 (not empty, not "0\n0") for a missing or
# empty file. `grep -c` prints 0 AND exits 1, so `grep -c . f || echo 0` emits TWO
# zeros — the same trap pg_count documents, and it produced invalid JSON here.
pg_lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# pg_now / pg_epoch — UTC timestamp and seconds (portable; no GNU date flags).
pg_now()   { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown; }
pg_epoch() { date +%s 2>/dev/null || echo 0; }

# pg_git_dir — this checkout's git dir (per-worktree state: verdict, impact).
# pg_common_dir — the shared one (state that must be identical across worktrees:
# the cache, the experiment worktrees themselves). They differ inside a worktree.
pg_git_dir()    { git rev-parse --git-dir 2>/dev/null || echo .git; }
pg_common_dir() { git rev-parse --git-common-dir 2>/dev/null || pg_git_dir; }

# pg_scalar <file> <key> — FIRST "key":"value" (or "key":bare) in a JSON file.
# The hook contract is grep-parseable single-line JSON, and `sed 's/.*"k":"\(..\)".*/'`
# is GREEDY — it silently returns the LAST match. Everything ProofGate reads back
# from its own JSON goes through this instead, which takes the first.
pg_scalar() {
  local f="$1" k="$2" v
  [ -f "$f" ] || return 0
  v="$(grep -o "\"$k\":\"[^\"]*\"" "$f" 2>/dev/null | head -1 | sed -e "s/^\"$k\":\"//" -e 's/"$//')"
  if [ -z "$v" ]; then
    v="$(grep -o "\"$k\":[^,}\"]*" "$f" 2>/dev/null | head -1 | sed -e "s/^\"$k\"://")"
  fi
  printf '%s' "$v"
}

# pg_json <file> <jq-path> / pg_json_list <file> <jq-path> — cfg's walkers, aimed
# at ANY json file (impact.json, memory.jsonl records, a proof note). Same
# jq → node → python3 chain, same degrade-to-empty contract.
pg_json()      { local f="$1"; shift; [ -f "$f" ] || return 0; PROOFGATE_CFG="$f" cfg "$@"; }
pg_json_list() { local f="$1"; shift; [ -f "$f" ] || return 0; PROOFGATE_CFG="$f" cfg_list "$@"; }

# pg_tree_hash — identity of the WORKING TREE (not just HEAD): HEAD sha + a hash of
# the unstaged/staged diff + the untracked file list. Two runs with the same value
# looked at exactly the same bytes, which is what a cache key has to mean. HEAD
# alone would happily serve a cached answer for a file you just edited.
pg_tree_hash() {
  local head diff unt
  head="$(git rev-parse HEAD 2>/dev/null || echo none)"
  diff="$(git diff HEAD 2>/dev/null | pg_sha1)"
  unt="$(git ls-files -o --exclude-standard 2>/dev/null | LC_ALL=C sort | pg_sha1)"
  printf '%s' "$head-$diff-$unt" | pg_sha1
}

# pg_content_id — an identity for the CODE, independent of which commit it sits on.
# Hash of every tracked blob plus every untracked file, so `git add -A && git commit`
# does not change it: the bytes are the same bytes.
#
# The scar, found by the end-to-end acceptance run: claims were keyed to the HEAD sha at
# the moment they were recorded, so committing ORPHANED every claim made before it. The
# natural order of work — do it, prove it, commit it, gate it — silently produced a
# delivery whose evidence had vanished, and the render said VERIFIED: NOTHING while the
# ledger was full. The alternative (record everything only after the final commit, and
# again after every amend) is exactly the kind of ceremony people stop performing.
#
# So evidence is bound to the code it was about, and stays attached across the commit
# that packages that code. It does NOT survive an actual change to the code — which is
# the property that matters, and the one this preserves.
pg_content_id() {
  # A map of path → the blob that is ACTUALLY there, not a union of index and worktree.
  # Listing both put a modified file in twice under two hashes, so the id changed at the
  # moment of committing — exactly the boundary it exists to survive. Later lines win.
  {
    git ls-files -s 2>/dev/null | awk '{print $4 " " $2}'
    git diff --name-only 2>/dev/null | while IFS= read -r f; do
      [ -f "$f" ] && printf '%s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
    done
    git ls-files -o --exclude-standard 2>/dev/null | while IFS= read -r f; do
      [ -f "$f" ] && printf '%s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
    done
  } | awk '{ blob[$1] = $2 } END { for (p in blob) print p " " blob[p] }' | LC_ALL=C sort | pg_sha1
}

# pg_lock <name> / pg_unlock <name> — mkdir is the only atomic primitive available
# everywhere (flock is Linux-only). Waits up to 5s, then reaps a lock whose mtime
# is older than 30s: a crashed writer must never wedge the next run.
pg_lock() {
  local d; d="$(pg_common_dir)/proofgate-lock-$1"; local i=0
  while ! mkdir "$d" 2>/dev/null; do
    if [ -d "$d" ] && [ -z "$(find "$d" -maxdepth 0 -mmin -0.5 2>/dev/null)" ]; then rmdir "$d" 2>/dev/null; continue; fi
    i=$((i + 1)); [ "$i" -gt 50 ] && return 1
    sleep 0.1 2>/dev/null || sleep 1
  done
  return 0
}
pg_unlock() { rmdir "$(pg_common_dir)/proofgate-lock-$1" 2>/dev/null || true; }

# pg_ledger_append <file> <json-object-without-closing-brace> — append one hash-
# chained line. Every ledger writer goes through this; the `prev` field is the sha1
# of the PREVIOUS line, so a line appended or edited by hand (an agent writing its
# own evidence) breaks the chain and the engine's `ledger-chain` check FAILs.
# This is tamper-EVIDENT, not tamper-proof: anything with a shell can recompute the
# chain. What it removes is the cheap, deniable edit.
pg_ledger_append() {
  local f="$1" body="$2" prev=""
  mkdir -p "$(dirname "$f")" 2>/dev/null
  pg_lock "$(basename "$f")" || return 1
  [ -f "$f" ] && prev="$(tail -1 "$f" 2>/dev/null | pg_sha1)"
  printf '%s,"prev":"%s"}\n' "$body" "$prev" >> "$f"
  pg_unlock "$(basename "$f")"
}

# ── calibration: is a guard earning its false positives? ─────────────────────
# Every guard trades signal against noise, and the trade is invisible from inside one
# run. A guard that fires constantly and is suppressed every time protects nothing — it
# trains people to reach for the escape hatch, and that habit generalises to the guards
# that matter. Three counters make the trade visible:
#
#   fired   — the guard produced a finding
#   allowed — someone silenced one (proofgate-allow, .proofgateignore, severity override)
#   scar    — a recorded incident credited this guard as what would have caught it
#
# High allowed/fired with zero scars is the demotion signal. It is REPORTED and never
# applied: a tool that quietly turned its own checks off after enough suppressions would
# automate exactly the erosion it exists to measure.
pg_calib() { # pg_calib <guard> <fired|allowed|scar> [detail]
  [ "$(cfg '.calibration' 2>/dev/null)" = "false" ] && return 0
  local f; f="$(pg_git_dir)/proofgate-calibration.jsonl"
  printf '{"ts":"%s","head_sha":"%s","guard":"%s","event":"%s","detail":"%s"}\n' \
    "$(pg_now)" "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$1" "$2" "$(pg_json_escape "${3:-}")" \
    >> "$f" 2>/dev/null || true
}

# ── lessons: a scar with nothing enforcing it yet ────────────────────────────
# The SKILL's escalation ladder says only levels 4 and 5 stand on their own — a guard
# that fails loud, or a design where the mistake is impossible. Everything below that
# depends on someone remembering. So an incident, or a finding the skeptic refused to
# drop, OPENS a lesson, and the gate keeps saying so until something at level 4+ answers
# it: a guard, a regression test, or an explicit memory entry. Writing a lesson down
# STORES it; this is what stops "stored" from being mistaken for "handled".
pg_lesson_add() { # pg_lesson_add <source> <ref> <text>
  local f=".proofgate/lessons.jsonl"
  mkdir -p .proofgate 2>/dev/null
  local id; id="L-$(printf '%s|%s' "$2" "$3" | pg_sha1 | cut -c1-6)"
  grep -q "\"id\":\"$id\"" "$f" 2>/dev/null && { printf '%s' "$id"; return 0; }
  pg_ledger_append "$f" "{\"id\":\"$id\",\"ts\":\"$(pg_now)\",\"event\":\"open\",\"source\":\"$1\",\"ref\":\"$(pg_json_escape "$2")\",\"head_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"text\":\"$(pg_json_escape "$3")\",\"resolved_by\":null,\"until\":0"
  printf '%s' "$id"
}
pg_lesson_resolve() { # pg_lesson_resolve <lesson-id> <kind> <ref>
  local f=".proofgate/lessons.jsonl"
  [ -f "$f" ] || return 0
  pg_ledger_append "$f" "{\"id\":\"$1\",\"ts\":\"$(pg_now)\",\"event\":\"resolve\",\"source\":\"\",\"ref\":\"\",\"head_sha\":\"$(git rev-parse HEAD 2>/dev/null || echo unknown)\",\"text\":\"\",\"resolved_by\":{\"kind\":\"$2\",\"ref\":\"$(pg_json_escape "$3")\"},\"until\":0"
}
# pg_lessons_open — ids with an `open` event and no `resolve`/unexpired `snooze`.
pg_lessons_open() {
  local f=".proofgate/lessons.jsonl"
  [ -f "$f" ] || return 0
  awk -v now="$(pg_epoch)" '
    match($0, /"id":"[^"]*"/) { id = substr($0, RSTART + 6, RLENGTH - 7) }
    match($0, /"event":"[^"]*"/) { ev = substr($0, RSTART + 9, RLENGTH - 10) }
    match($0, /"until":[0-9]*/) { u = substr($0, RSTART + 8, RLENGTH - 8) + 0 }
    match($0, /"text":"[^"]*"/) { t = substr($0, RSTART + 8, RLENGTH - 9) }
    { st[id] = ev; if (t != "") txt[id] = t; if (ev == "snooze") snz[id] = u }
    END { for (i in st) if (st[i] == "open" || (st[i] == "snooze" && snz[i] < now)) print i "\t" txt[i] }
  ' "$f" 2>/dev/null
}

# pg_ledger_verify <file> — 0 = chain intact (or file absent). Prints the 1-based
# number of the first line whose recorded `prev` is not the hash of the line before it.
pg_ledger_verify() {
  local f="$1" n=0 previous="" claimed actual
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    n=$((n + 1))
    claimed="$(printf '%s' "$line" | grep -o '"prev":"[^"]*"' | tail -1 | sed -e 's/^"prev":"//' -e 's/"$//')"
    actual=""
    [ -n "$previous" ] && actual="$(printf '%s\n' "$previous" | pg_sha1)"
    if [ "$claimed" != "$actual" ]; then printf '%s' "$n"; return 1; fi
    previous="$line"
  done < "$f"
  return 0
}
