# Changelog

## 1.0.0 — 2026-07-03

First public release. Extracted and generalized from a private production
project where every rule earned a scar first.

### Added
- **Mechanical gate** (`verify.sh`): stack auto-detection (pnpm/npm/yarn/bun,
  Cargo, Go, Python), git committed+pushed checks, `--build`, `--strict`,
  `--dry-run`, `--base`, `--report`.
- **7 guards** (`guards.d/`): secrets-in-diff (FAIL), PII-into-logs,
  untested changes, env-var drift, coupled files, large files,
  debug leftovers (focused tests = FAIL).
- **Guard plugin contract** + `TEMPLATE.sh.example` — a new guard is one
  dropped file.
- **Judgment gate** (`SKILL.md`): 9 evidence-demanding questions; Claude Code
  skill packaging (plugin + marketplace manifests).
- **Templates**: Evidence Report (VERIFIED / NOT TESTED / PARTIAL) and
  Root-Cause Analysis (failure layer, regression pin, strike counter).
- **Installer** (`install.sh`): vendors the gate into any repo; `--hook`
  (pre-push) and `--ci` (GitHub Actions workflow) options.
- **GitHub Action** (`action.yml`) for CI use straight from this repo.
- **Self-tests** (`tests/run-tests.sh`): every guard proven on positive AND
  negative paths; CI runs them on every push.
