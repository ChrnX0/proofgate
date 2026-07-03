#!/usr/bin/env bash
# ProofGate installer — vendors the gate into the CURRENT repo, so it runs with
# zero external dependencies from day one.
#
#   curl -fsSL https://raw.githubusercontent.com/ChrnX0/proofgate/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --hook     # + git pre-push hook
#   curl -fsSL .../install.sh | bash -s -- --ci       # + GitHub Actions workflow
#   bash install.sh --hook --ci                       # from a local clone
#
# What it does (and nothing else):
#   1. copies verify.sh + guards.d/ into .proofgate/ in your repo
#   2. --hook: wires .git/hooks/pre-push to run the gate before every push
#   3. --ci:   writes .github/workflows/proofgate.yml (warn-only to start)
set -euo pipefail

HOOK=0 CI=0
for a in "$@"; do case "$a" in --hook) HOOK=1 ;; --ci) CI=1 ;; esac; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run me inside a git repo"; exit 1; }
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
DEST="$ROOT/.proofgate"

mkdir -p "$DEST"
if [ -f "$SRC_DIR/skills/proofgate/scripts/verify.sh" ]; then
  # Local clone: copy straight from it.
  cp "$SRC_DIR/skills/proofgate/scripts/verify.sh" "$DEST/verify.sh"
  rm -rf "$DEST/guards.d" && cp -r "$SRC_DIR/skills/proofgate/scripts/guards.d" "$DEST/guards.d"
else
  # Curled: fetch the tarball once, take only what we vendor.
  TMP="$(mktemp -d)"
  curl -fsSL https://github.com/ChrnX0/proofgate/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
  cp "$TMP"/proofgate-main/skills/proofgate/scripts/verify.sh "$DEST/verify.sh"
  rm -rf "$DEST/guards.d" && cp -r "$TMP"/proofgate-main/skills/proofgate/scripts/guards.d "$DEST/guards.d"
  rm -rf "$TMP"
fi
chmod +x "$DEST/verify.sh" "$DEST"/guards.d/*.sh 2>/dev/null || true
echo "✅ vendored: .proofgate/verify.sh (+ $(ls "$DEST/guards.d" | grep -c '\.sh$') guards)"

if [ "$HOOK" = 1 ]; then
  mkdir -p "$ROOT/.git/hooks"
  cat > "$ROOT/.git/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
# ProofGate pre-push hook — you cannot push unproven work.
# Bypass for emergencies (leaves a trace in your shame ledger): git push --no-verify
exec bash "$(git rev-parse --show-toplevel)/.proofgate/verify.sh"
EOF
  chmod +x "$ROOT/.git/hooks/pre-push"
  echo "✅ pre-push hook installed (bypass: --no-verify, if you must)"
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
      # Start warn-only; flip strict to "true" when the team is ready.
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
echo "Judgment gate: https://github.com/ChrnX0/proofgate#the-judgment-gate-layer-2"
