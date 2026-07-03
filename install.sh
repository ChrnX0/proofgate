#!/usr/bin/env bash
# ProofGate installer — vendors the gate into the CURRENT repo, so it runs with
# zero external dependencies from day one.
#
#   curl -fsSL https://raw.githubusercontent.com/ChrnX0/proofgate/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --hook       # + git pre-push hook (chains any existing one)
#   curl -fsSL .../install.sh | bash -s -- --ci         # + GitHub Actions workflow
#   bash install.sh --hook --ci --stop-hook             # from a local clone
#   bash install.sh --uninstall                         # remove what we added
#
# What it does (and nothing else):
#   1. copies verify.sh + lib.sh + guards.d/ + templates/ into .proofgate/
#   2. --hook: wires .git/hooks/pre-push to gate before every push (existing hook
#      is preserved as pre-push.local and still runs — we never clobber it)
#   3. --ci: writes .github/workflows/proofgate.yml (warn-only to start)
#   4. --stop-hook: sets "stopGuard": true in proofgate.json (the plugin's Stop hook
#      then refuses "done" without a fresh passing verdict — opt-in, off by default)
set -euo pipefail

HOOK=0 CI=0 STOP=0 UNINSTALL=0
for a in "$@"; do case "$a" in
  --hook) HOOK=1 ;; --ci) CI=1 ;; --stop-hook) STOP=1 ;; --uninstall) UNINSTALL=1 ;;
esac; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run me inside a git repo"; exit 1; }
GD="$(git rev-parse --git-dir)"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
DEST="$ROOT/.proofgate"
MARK="# ProofGate pre-push hook"

if [ "$UNINSTALL" = 1 ]; then
  rm -rf "$DEST"
  if [ -f "$GD/hooks/pre-push" ] && grep -q "$MARK" "$GD/hooks/pre-push" 2>/dev/null; then
    if [ -f "$GD/hooks/pre-push.local" ]; then mv "$GD/hooks/pre-push.local" "$GD/hooks/pre-push"; else rm -f "$GD/hooks/pre-push"; fi
  fi
  [ -f "$ROOT/.github/workflows/proofgate.yml" ] && grep -q 'proofgate' "$ROOT/.github/workflows/proofgate.yml" && rm -f "$ROOT/.github/workflows/proofgate.yml"
  echo "✅ uninstalled .proofgate/ + hook + CI workflow (your proofgate.json is left untouched — it's your config)"
  exit 0
fi

mkdir -p "$DEST"
vendor() { # copy from local clone if present, else from the release tarball
  if [ -f "$SRC_DIR/skills/proofgate/scripts/verify.sh" ]; then
    cp "$SRC_DIR/skills/proofgate/scripts/verify.sh" "$DEST/verify.sh"
    cp "$SRC_DIR/skills/proofgate/scripts/lib.sh" "$DEST/lib.sh"
    rm -rf "$DEST/guards.d" && cp -r "$SRC_DIR/skills/proofgate/scripts/guards.d" "$DEST/guards.d"
    rm -rf "$DEST/templates" && cp -r "$SRC_DIR/templates" "$DEST/templates" 2>/dev/null || true
  else
    local TMP; TMP="$(mktemp -d)"
    curl -fsSL https://github.com/ChrnX0/proofgate/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
    cp "$TMP"/proofgate-main/skills/proofgate/scripts/verify.sh "$DEST/verify.sh"
    cp "$TMP"/proofgate-main/skills/proofgate/scripts/lib.sh "$DEST/lib.sh"
    rm -rf "$DEST/guards.d" && cp -r "$TMP"/proofgate-main/skills/proofgate/scripts/guards.d "$DEST/guards.d"
    rm -rf "$DEST/templates" && cp -r "$TMP"/proofgate-main/templates "$DEST/templates" 2>/dev/null || true
    rm -rf "$TMP"
  fi
}
vendor
chmod +x "$DEST/verify.sh" "$DEST"/guards.d/*.sh 2>/dev/null || true
set -- "$DEST"/guards.d/*.sh; echo "✅ vendored: .proofgate/verify.sh + lib.sh (+ $# guards)"

if [ "$HOOK" = 1 ]; then
  mkdir -p "$GD/hooks"
  # Preserve any pre-existing hook (that isn't already ours) as pre-push.local.
  if [ -f "$GD/hooks/pre-push" ] && ! grep -q "$MARK" "$GD/hooks/pre-push" 2>/dev/null; then
    mv "$GD/hooks/pre-push" "$GD/hooks/pre-push.local"
    chmod +x "$GD/hooks/pre-push.local" 2>/dev/null || true
    echo "▫️  kept your existing pre-push as pre-push.local (it still runs first)"
  fi
  cat > "$GD/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
# ProofGate pre-push hook — you cannot push unproven work.
# Bypass for emergencies (leaves a trace in your shame ledger): git push --no-verify
REFS="$(cat)"                                  # git feeds refs on stdin — capture once
ROOT="$(git rev-parse --show-toplevel)"; GD="$(git rev-parse --git-dir)"
if [ -x "$GD/hooks/pre-push.local" ]; then
  printf '%s' "$REFS" | "$GD/hooks/pre-push.local" "$@" || exit $?
fi
V="$GD/proofgate-verdict.json"; HEAD_SHA="$(git rev-parse HEAD)"
if [ -f "$V" ] && grep -q '"pass":true' "$V" 2>/dev/null \
   && [ "$(sed -n 's/.*"sha":"\([0-9a-f]\{7,40\}\)".*/\1/p' "$V" | head -1)" = "$HEAD_SHA" ]; then
  exit 0                                        # fresh passing verdict → fast path
fi
exec bash "$ROOT/.proofgate/verify.sh"
EOF
  chmod +x "$GD/hooks/pre-push"
  echo "✅ pre-push hook installed (bypass: --no-verify, if you must)"
fi

if [ "$STOP" = 1 ]; then
  CFGF="$ROOT/proofgate.json"
  if [ -f "$CFGF" ] && grep -q '"stopGuard"' "$CFGF"; then
    echo "▫️  proofgate.json already has stopGuard — left as-is"
  elif [ -f "$CFGF" ] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"; jq '. + {stopGuard:true}' "$CFGF" > "$tmp" && mv "$tmp" "$CFGF"
    echo "✅ stopGuard enabled in proofgate.json (the plugin Stop hook now refuses 'done' without a fresh verdict)"
  elif [ ! -f "$CFGF" ]; then
    printf '{\n  "stopGuard": true\n}\n' > "$CFGF"
    echo "✅ created proofgate.json with stopGuard: true"
  else
    echo "⚠️  add \"stopGuard\": true to proofgate.json by hand (no jq to edit it safely)"
  fi
fi

if [ "$CI" = 1 ]; then
  mkdir -p "$ROOT/.github/workflows"
  if [ ! -f "$ROOT/.github/workflows/proofgate.yml" ]; then
    cat > "$ROOT/.github/workflows/proofgate.yml" <<'EOF'
name: proofgate
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      # Start warn-only; add --strict when the team is ready.
      - run: bash .proofgate/verify.sh --report proofgate-report.md
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: proofgate-report, path: proofgate-report.md, if-no-files-found: ignore }
EOF
    echo "✅ CI workflow written: .github/workflows/proofgate.yml"
  else
    echo "▫️ .github/workflows/proofgate.yml already exists — left untouched"
  fi
fi

echo
echo "Run it now:   bash .proofgate/verify.sh --dry-run"
echo "Judgment gate: https://github.com/ChrnX0/proofgate#-what-proofgate-actually-is"
