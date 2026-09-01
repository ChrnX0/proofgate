#!/usr/bin/env bash
# Guard: a dependency manifest changed but its lockfile did not.
# The scar: adding a dep to package.json / Cargo.toml / go.mod without committing
# the updated lockfile means CI resolves a DIFFERENT version than you tested —
# "works on my machine" shipped as a diff. (We flag only the lockfile-drift half;
# warning on every dependency bump would be pure noise — teams that want the
# "justify every new dep" behavior can raise this guard's severity in config.)
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# The dependency blocks of a JSON manifest at one revision, normalised.
#
# The heuristic below asks whether an added line "looks dependency-shaped", and
# in JSON every line does - it has a quote. So renaming a script, or adding one,
# warned that a lockfile was missing when no lockfile could possibly change. A
# warning that is wrong every time teaches people to skip the warnings that are
# not, so this compares the blocks that actually decide resolution.
#
# Prints nothing and returns 1 when no JSON parser is around; the caller then
# falls back to the old heuristic rather than guessing.
json_deps() { # json_deps <rev>:<path>
  local blob; blob="$(git show "$1" 2>/dev/null)" || return 1
  [ -n "$blob" ] || return 1
  local keys='dependencies devDependencies peerDependencies optionalDependencies overrides resolutions require require-dev'
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$blob" | python3 -c 'import sys,json
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
keys = "'"$keys"'".split()
print(json.dumps({k: d.get(k) for k in keys}, sort_keys=True))' && return 0
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$blob" | jq -S -c '{dependencies,devDependencies,peerDependencies,optionalDependencies,overrides,resolutions,require,"require-dev":.["require-dev"]}' && return 0
  fi
  return 1
}

BASE="${PROOFGATE_BASE:?}"
CHANGED="$(git diff --name-only "$BASE"..HEAD 2>/dev/null)"

# "manifest|lock1 lock2 ..." — any one lock present in the diff clears the manifest.
PAIRS='package.json|pnpm-lock.yaml package-lock.json yarn.lock bun.lockb bun.lock npm-shrinkwrap.json
Cargo.toml|Cargo.lock
go.mod|go.sum
pyproject.toml|poetry.lock uv.lock pdm.lock
Gemfile|Gemfile.lock
composer.json|composer.lock
mix.exs|mix.lock'

drift=""
while IFS='|' read -r manifest locks; do
  [ -n "$manifest" ] || continue
  mpath="$(echo "$CHANGED" | grep -E "(^|/)$manifest\$" | head -1)"
  [ -n "$mpath" ] || continue
  # For a JSON manifest, ask the blocks that actually decide resolution. Equal
  # blocks mean no lockfile could have changed, whatever else moved in the file.
  case "$mpath" in
    *.json)
      before="$(json_deps "$BASE:$mpath")" && after="$(json_deps "HEAD:$mpath")" && {
        [ "$before" = "$after" ] && continue
      }
      ;;
  esac

  # Was a dependency-shaped line actually ADDED to the manifest? (version specifier present)
  hits="$(git diff "$BASE"..HEAD -- "$mpath" 2>/dev/null | grep -E '^\+' | grep -Ec '[">=~^]|require |gem |implementation ' || true)"
  [ "${hits:-0}" -gt 0 ] || continue
  cleared=""
  for l in $locks; do echo "$CHANGED" | grep -Eq "(^|/)$l\$" && { cleared=1; break; }; done
  [ -z "$cleared" ] && drift="$drift $manifest"
done <<EOF
$PAIRS
EOF

drift="$(printf '%s' "$drift" | sed 's/^ //')"
if [ -n "$drift" ]; then
  echo "⚠️  dependency-change: manifest changed without its lockfile ($drift) — CI will resolve versions you never tested. Commit the updated lockfile."
  exit 2
fi
echo "✅ dependency-change: manifests and lockfiles moved together"
exit 0
