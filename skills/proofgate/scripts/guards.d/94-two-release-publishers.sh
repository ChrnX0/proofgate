#!/usr/bin/env bash
# Guard: two workflows can publish to the same release tag, and each computes that tag itself.
#
# The scar (2026-09-04, ChrnX0/Norva). The repository grew a second way to ship its
# Android installer. The new one built the APK in-repo and published it; the old one
# downloaded a prebuilt artifact from a cloud builder and attached that. The old one had
# not published legitimately in three days — but it was still dispatchable, and its
# pinned artifact pointer had not moved in 177 commits.
#
# Both derived the release tag the same way, from the version in the manifest:
#   TAG="apk-$(node -p "require('./app.json').expo.version")"
# So dispatching the stale one landed a 110 MiB binary from 177 commits back INSIDE the
# good release, beside the good binary, under a note naming the good commit. Worse than
# two files: the two were signed with different keys, so whoever downloaded the wrong one
# could not install over the other and lost their data uninstalling.
#
# The old workflow's own docblock described that exact failure and claimed it fixed. The
# fix had changed the TRIGGER (pull_request -> workflow_dispatch), which stopped the
# AUTOMATIC republish, and left the stale payload. The bug had two halves — when it runs
# and what it runs — and the repair treated the first as the whole thing.
#
# The general failure, which is why this is a guard and not a note: a release tag is a
# single-writer namespace, and nothing in CI enforces that. Two publishers that each
# compute the tag from the same manifest are two writers who will never see each other's
# assets, so the loser is decided by dispatch order. This is the delivery-side twin of a
# piece with no caller: the unused publisher is not dead, it is ARMED, and its blast
# radius is the one artifact a user actually installs.
#
# A publisher whose tag comes from the event (a pushed tag, a workflow input, github.ref)
# is NOT counted: there the caller names the target, so two of them are a designed pair —
# typically one creating a draft and another uploading assets to it. Only self-computed
# tags collide silently.
#
# WARN, never FAIL: a repo may legitimately publish two artifacts under one tag (an APK
# and its mapping file, a binary per platform). The question this asks is whether that is
# the design or an accident, and it names the files so the answer takes one look.
#
# It measures STATE, not the diff — a second publisher is not an event, it is a condition,
# and it bites at publish time, not at commit time. So the diff only decides WHEN to look:
# the guard runs when the delivery touches release machinery or raises a version, which is
# exactly when someone is about to publish.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
BASE="${PROOFGATE_BASE:?}"

CHANGED="$(git diff --name-only "$BASE"..HEAD | grep -Ev '(guards\.d/|^\.proofgate/)' || true)"
[ -n "$CHANGED" ] || { echo "✅ release-publishers: nothing in the diff"; exit 0; }

# WHEN to look: the delivery touches CI/release machinery, or raises a version.
MANIFESTS='(^|/)(package\.json|plugin\.json|Cargo\.toml|pyproject\.toml|composer\.json|pubspec\.yaml|app\.json)$'
OLHAR=0
printf '%s\n' "$CHANGED" | grep -Eq '(^|/)\.github/workflows/' && OLHAR=1
if [ "$OLHAR" = 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$f" | grep -Eq "$MANIFESTS" || continue
    if git diff -U0 "$BASE"..HEAD -- "$f" 2>/dev/null | grep -E '^\+' \
        | grep -Eq '"?version"?[[:space:]]*[:=][[:space:]]*"?[0-9]+\.[0-9]+'; then
      OLHAR=1
      break
    fi
  done <<EOF
$CHANGED
EOF
fi
[ "$OLHAR" = 0 ] && { echo "✅ release-publishers: delivery touches no release machinery"; exit 0; }

[ -d .github/workflows ] || { echo "✅ release-publishers: no GitHub workflows in the repo"; exit 0; }

# A workflow that WRITES a release. Reading one (`gh release view`) is not publishing.
ESCREVE='gh release (create|upload|edit)|softprops/action-gh-release|actions/create-release|ncipollo/release-action|actions/upload-release-asset'
# The tag came from OUTSIDE the workflow: the caller names the target, so it cannot
# silently collide with another publisher's idea of the tag.
DE_FORA='github\.ref_name|github\.ref|inputs\.tag|github\.event\.release|matrix\.tag|env\.RELEASE_TAG'

AUTORES=""
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  grep -Eq "$ESCREVE" "$wf" || continue
  # Does it derive its own tag? Either from a version manifest, or from a literal it
  # builds itself. If the only tag source is the event/input, it is parameterized.
  if grep -Eq "$DE_FORA" "$wf" && ! grep -Eq '(TAG|tag_name|RELEASE).*(version|VERSION)' "$wf"; then
    continue
  fi
  AUTORES="$AUTORES $wf"
done

QUANTOS="$(printf '%s' "$AUTORES" | wc -w | tr -d ' ')"
if [ "$QUANTOS" -lt 2 ]; then
  echo "✅ release-publishers: at most one workflow computes its own release tag"
  exit 0
fi

echo "⚠️  two or more workflows publish under a tag they compute themselves:$AUTORES"
echo "    A release tag is a single-writer namespace and nothing in CI enforces it. Each of"
echo "    these derives the tag on its own, so neither sees the other's assets and dispatch"
echo "    order decides the winner — a stale one lands an old binary INSIDE the good release."
echo "    Check each: does it still have a legitimate caller, and is the payload it ships"
echo "    built from THIS commit? An unused publisher is not dead, it is armed. If two"
echo "    publishers under one tag IS the design (an APK and its mapping file), say so."
exit 2
