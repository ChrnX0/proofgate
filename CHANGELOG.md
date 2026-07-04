# Changelog

## 2.0.0 — 2026-07-03

The gate becomes a system. From a checklist-with-a-script to four layers:
a mechanical gate with a machine-readable verdict, a judgment gate with an
evidence hierarchy, an adversarial skeptic, and hooks that make unproven work
literally un-pushable.

### Added
- **SHA-bound verdict** — every full run writes `.git/proofgate-verdict.json`
  (`{sha, checks[], fails, warns, pass}`), never committed. `--json` prints it.
- **10 new guards** (7 → **17**): merge-markers (FAIL), tls-off (FAIL / curl-`-k`
  WARN), silent-catch, dependency-lockfile drift, skipped-tests, frozen-clock
  (wall-clock in tests), type-suppressions (`@ts-ignore`/`noqa`/`nosec`),
  machine-paths, float-money, sql-concat. `10-secrets` gains a generic-assignment
  WARN + `secretAllowlist`.
- **Push-guard hook** (PreToolUse Bash) — refuses `git push` without a fresh
  passing verdict, and catches `--no-verify` / `core.hooksPath` bypass attempts
  that a git pre-push hook can't. Fail-open, opt-in.
- **Stop-guard hook** (opt-in, **off by default**) — refuses to declare "done"
  without a fresh passing verdict (`stopGuard: true`).
- **gate-skeptic subagent** + **`/proofgate:gate`** slash command — an adversarial
  default-refute pass over your claims.
- **Production smoke** (`--smoke`, config `smoke[]`) — GET (status + body regex)
  or `cmd`, as a mechanical post-deploy proof.
- **Config**: `skip`, `severity`, `guardsDirs` (repo-local guards), `moneyTerms`,
  `secretAllowlist`, `timeoutSeconds`, `maxFileKb`, `smoke`, `pushGuard`, `stopGuard`.
- **Zero-dep config** (`lib.sh`): jq → node → python3 fallback (v1 silently ignored
  config without jq). Per-finding suppression via `.proofgateignore` + inline
  `proofgate-allow`.
- **More stacks**: Gradle/Maven, .NET, Ruby, PHP, Elixir, Deno. `lint` now runs.
- **Evidence hierarchy** in `SKILL.md` (E0 believed → E4 in-prod; "done" ≥ E3),
  the 5-step gate function, banned-language list, and an excuse-buster table.
- **CI**: engine + hook coverage in `run-tests.sh` (16 → **61** cases), macOS matrix
  (bash 3.2 / BSD grep), and **blocking** shellcheck.
- **GitHub Actions**: `::error`/`::warning` annotations, step-summary, action outputs
  (`fails`/`warns`/`verdict-path`).

### Changed
- **BREAKING (semantics):** unpushed HEAD is now a **WARN**, not a FAIL — the push
  itself is the gated step (via the push-guard), so requiring a push to pass while
  gating the push would deadlock. `pass = (fails == 0)`.
- `install.sh --hook` now **chains** an existing pre-push hook (saved as
  `pre-push.local`) instead of clobbering it; adds `--stop-hook` and `--uninstall`.
- The "build NOT run" line is an informational **note** (▫️), not a warning — so
  `--strict` no longer always fails without `--build`.

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
