# Changelog

## 2.7.0 — 2026-09-01

Four guards, each from a failure that actually happened — including one of the
gate's own.

### Added
- **`99-dead-allow` — a `proofgate-allow` that suppresses nothing.** The marker is
  matched against the added line ITSELF. Written on the comment line above the code
  it means to excuse, it does nothing at all, while reading exactly like a handled
  finding: the author moves on, the warning keeps counting, and nobody looks because
  the summary only shows a number. A "resolved" sign wired to nothing is worse than
  the warning it appears to answer — same family as a green test that exercises no
  rule. Found by wearing the gate: three markers sat in comments for hours, and the
  ⚠️ count never moved.
- **`92-superuser-verification` — a verification path that bypasses row level
  security.** A schema harness replayed a client's entire write queue against real
  Postgres and passed: forty-five writes, not one refusal. It connected as
  `postgres`, and a superuser bypasses RLS outright, so every policy was off. The run
  proved the columns agreed and nothing whatsoever about whether the server would
  accept the writes — and the one rule that decided the feature was never executed.
  A wrong premise then survived a full green bar and got built on top of. Fires only
  where policies exist, since a repo without RLS has nothing to bypass.
- **`97-migration-edited` — a step edited instead of appended.** A migration that has
  already run leaves that database in the shape the old text produced; editing the
  file changes only what a fresh database gets. The two diverge in silence, every
  checkout looks fine, and it surfaces months later as a column that exists on one
  machine and not another. Matches on the migrations DIRECTORY, not the word: a
  script called `verify-migrations.sh` verifies migrations, it is not one, and a
  guard that cannot tell those apart gets switched off by the first person it annoys.
- **`48-pipeline-exit-code` — `$?` read after a pipeline.** `npm run e2e 2>&1 |
  tail -3` then `echo $?` reports *tail's* status, and tail succeeds at printing
  three lines of a failure. What made it expensive: the run was checking whether a
  guard exits non-zero on an empty suite, so "prints the message but exits 0" was
  the exact defect being fixed — the wrong reading looked like the bug reproducing.
  Fires only where `pipefail` is absent, since with it the reading is sound.
- **`47-unquoted-globstar` — a `**` glob handed to the shell.**
  `"test": "tsx --test src/**/*.test.ts"`. The shell expands that before the
  runner sees it and, without `globstar`, reads `**` as a single directory level.
  A test file one level shallower was never executed, and the suite reported
  success for a file it had not opened — a test that does not run looks exactly
  like a test that passes. Found by counting: a new file was added and the total
  did not move.
- **`45-broad-process-kill` — killing by name pattern instead of by PID.** A
  `pkill -f verify.sh` meant to clear a stale run killed the run that had just
  started too: both match the same name. The expensive part was not the lost cycle
  but the output, which looked like a crash rather than a self-inflicted kill.

### Fixed
- **`90-sql-concat` no longer warns on the shell's `||`.** `psql -c "insert into t
  ...;" || fail` has exactly the shape the guard was looking for — a quote, then
  the bars — and so does SQL's `'abc' || col`. Nothing on the line separates them,
  so the file type does: shell scripts are excluded from that branch alone and keep
  every other pattern. Found by the guard warning on a correct line.
- **`35-dependency-change` compares the dependency blocks instead of guessing at
  line shape.** It asked whether an added line looked dependency-shaped — a quote,
  a caret, a tilde — and in JSON every line does. Renaming or adding a `scripts`
  entry demanded a lockfile that could not possibly change, on every run, for
  weeks. A warning that is wrong every time is worse than no warning: it teaches
  people to skip the ones that are right. Now the manifest's dependency,
  devDependency, peer, optional, override, resolution and `require` blocks are
  read at both revisions and compared; equal blocks end it. Falls back to the old
  heuristic where no JSON parser exists, rather than guessing.
- **`90-sql-concat` no longer reads hex as a Python f-string.** The branch matched
  `f` followed by a quote with no boundary before it, so any word ending in `f`
  next to a quote counted — and hex is full of them. A line inserting the uuid
  `...00000000000f` warned because `f'` sits in the data.

All four new guards ship with positive AND negative cases in `tests/run-tests.sh`
(**101**, up from 81), including the two false positives found by wearing them:
`92-superuser-verification` fired on this very changelog's kind of prose — a
comment explaining why `-U postgres` is wrong — and a guard that flags the warning
against a sin teaches people to stop writing the warning. It also silently matched
nothing at first: `$SUPER` starts with `-U`, and `grep -E "$pattern"` without `--`
reads that as an option.

## 2.6.0 — 2026-08-07

`--only` can finally run the guard you just wrote.

### Fixed
- **`--only <guard>` now searches `config.guardsDirs`, not just the engine's own
  `guards.d`.** A full run walks both; `--only` walked one. The effect was backwards
  from what anyone would want: the guards that ship with ProofGate — already covered by
  this repo's own test suite — were the ones you could run in isolation, and the project
  guard you had just authored was the one you could not.

  The failure was quiet, which is what made it cost time. `--only my-guard` answered
  `no guard named 'my-guard'`, which reads like "your file is misnamed" and not like
  "this flag doesn't look there". The real way to confirm a project guard had run at all
  was to finish a full gate and read its name out of the verdict ledger
  (`.git/proofgate-verdict.json`) — because a guard that passes usually prints nothing,
  so absence from the console proves nothing either way.

  Two consequences worth naming, since both are about iteration speed:

  - authoring a guard no longer requires a full typecheck/lint/test cycle per attempt;
  - the "not found" message now lists **every** directory that was searched, so a real
    typo and a mislocated file look different.

  A guard that passes silently is still ambiguous on the console. If you write one,
  consider printing a one-line ✅ on the clean path — the engine records `pass` in the
  ledger either way, but the person reading the terminal has no other signal.

## 2.5.0 — 2026-08-05

The mutation rule gets a runner — and it fails loud when it does nothing.

### Added
- **`skills/proofgate/scripts/mutate.mjs`** — mutation as proof of test, runnable.
  Point it at a source file and a test command, feed it mutations as JSONL, and it
  reports which ones the suite failed to notice.

  ```sh
  node skills/proofgate/scripts/mutate.mjs src/pricing.ts -- npx vitest run src/pricing.test.ts < m.jsonl
  ```

  2.4.0 added this as a judgment-layer rule ("break the line the test is supposed to
  protect, and confirm it screams") and deliberately left it unmechanized. It stayed
  skipped, for the reason disciplines always are: doing it by hand is fiddly, and a
  hand-rolled loop that silently does nothing looks exactly like a hand-rolled loop that
  found nothing. That happened twice in one session — wrong working directory, no output,
  read as green.

  So the runner is built to fail loud. Empty stdin is exit **2**, not success. A baseline
  that is already red is exit **2** — otherwise "killed" might be an unrelated breakage and
  the whole report is a lie. A `from` string that is not unique in the file is exit **2**,
  because a near-miss edits the wrong place and reports a confident, meaningless result.
  Survivors are exit **1** with the list. The file is restored on every path, including
  SIGINT. The only exit **0** is "every mutation was caught".

  It earned its keep immediately: on the delivery that motivated it, 47 mutations found
  **6 blind tests** — six rules the suite was named for and did not cover.

### Added — excuse-buster rows
- **"The comment says it's safe — I wrote it when I wrote the code."** A comment asserting
  a security property is an E3 claim wearing a comment's clothes. The scar: a comment
  promising that re-joining a contest "never grants more credit" sat directly above code
  where re-joining moved the start date — cutting the numerator *and* the denominator.
  Two players with identical performance; the one who toggled the switch came out champion,
  and the existing test asserted the buggy behavior as desired. Documenting a safety
  property backwards is worse than not documenting it: the next reader skips the check
  exactly where it was needed.

- **"Typecheck / the suite was green."** Green *when*? Evidence has a timestamp. A command
  that ran before the last file existed says nothing about that file — and the natural order
  of work (code, then tests, then verify) puts the mid-way run before the thing most likely
  to be wrong. The mid-way run is a draft. Re-run it fresh as the last thing before claiming.

### Not a guard, deliberately
  Neither new row mechanizes cleanly. Flagging comments that contain safety words
  ("never", "cannot", "safe") in a diff without a test change fires on ordinary prose and
  on every honest caveat; and "is this evidence stale?" is already covered by the SHA-bound
  verdict for the gate itself, which cannot see an ad-hoc command you ran in a terminal.
  CONTRIBUTING puts low false-positive above all — these stay at the judgment layer.

## 2.4.0 — 2026-08-01

A green suite is evidence about the suite, not about the code.

### Added
- **Excuse-buster row** for *"I wrote the tests and they all passed on the first run"*.
  A test that has never been red has never proven it can see anything. The remedy is
  cheap and nobody does it: break the line the test is supposed to protect, and confirm
  it screams.

  The scar. A repository function filtered attendance records down to the ones strong
  enough to be trusted — the anti-fraud rule the whole feature rested on. Its test was
  named for exactly that, seeded a student with only forgeable records, and asserted the
  result came back `blocked`. Green. Then a mutation run deleted the filter from the SQL
  entirely — every forgeable record now counted — and the suite stayed green. The fixture
  had been landing on `blocked` through a *different* cause (the gym had no verified
  channel at all), so the assertion never exercised the filter once. The fix was one line
  of fixture: turn the channel on via another student, isolating the only remaining cause.
  Then the mutation dies.

  Generalized: **an assertion on an outcome that several causes produce tests none of
  them.** `=== null`, `toThrow()`, an error state, a falsy return — all are outcomes with
  many roads leading in.

### Not a guard, deliberately
  The obvious mechanization — flag test files whose assertions are all "absence" shaped —
  fires on every legitimate leak test (`expect(log).not.toContain(ssn)`), which is some of
  the most valuable test code there is. CONTRIBUTING puts low false-positive above all,
  and a guard that cries on good tests is how a gate gets aliased away. This one stays at
  the judgment layer, where a human reads it and decides.

## 2.3.0 — 2026-07-30

The gate learns the difference between **merged** and **released**.

### Added
- **`96-version-bump-no-release`** (19th guard, WARN) — a version raised in a manifest
  (`package.json`, `plugin.json`, `Cargo.toml`, `pyproject.toml`, `build.gradle`,
  `pubspec.yaml`, …) with nothing in the delivery that cuts a release. The scar, from
  this project's own 2.2.0: the manifests went to 2.2.0, the CHANGELOG gained its
  section, the PR merged green, and the delivery was reported as *"merged, public"* —
  then the owner opened the repository and saw **2.0.0**. Both statements were true and
  only one mattered: no tag or release had ever been cut. A manifest bump is invisible
  to everyone who is not reading the diff; the release IS the shop window.

  Stays quiet when the delivery itself handles the release — release automation
  (changesets, release-please, semantic-release, goreleaser) or a tag-triggered
  workflow — and when a manifest is edited for anything other than its version, which
  is the false positive that would otherwise fire on every dependency bump.

- **Excuse-buster row** for *"it's merged / it's on main, so it's shipped"*: merged and
  released are different events, and a bump feels like the second while being the first.

### Tests
- Four guard cases (73 total, was 69): fires on the bare bump; silent with release
  automation; silent with a tag-triggered workflow; silent on a manifest edit that does
  not touch the version.

## 2.2.0 — 2026-07-30

The gate learns to say when it was looking at nothing. Until now a run made
**after** the work was merged could report every guard green while inspecting a
diff that no longer contained the work.

### Added
- **`sourceless-diff`** (engine warning) — fires when the guarded diff contains no
  source file at all. The trap it closes: `--base` defaults to the merge-base with
  the default branch, so once a delivery is fast-forwarded onto that branch, the
  base moves *with* the delivery and the guarded diff collapses to whatever landed
  afterwards — usually a docs commit. Every diff-based guard then prints its calm
  "nothing touched" line, which reads exactly like approval. The scar: a run
  reported *"mobile app not touched in this diff"*, *"no core source in this diff"*
  and *"0 source / 0 test file(s)"* minutes after that same delivery added two core
  modules and changed the mobile app — three of the guards that mattered most were
  silently disabled. Guards cannot detect this from the inside: to a guard, an
  empty diff is indistinguishable from a clean one. Only the engine knows how big
  the diff it handed them was. The fix is to re-run with `--base <sha before the
  block>`.
- **Excuse-buster row** for *"the gate passed — every guard came back green"*:
  green on **which diff**? Read the guard output for lines that CONTRADICT what you
  just wrote.

### Tests
- Two engine cases (69 total, was 67): a docs-only diff warns; a diff carrying
  source stays silent.

## 2.1.0 — 2026-07-30

Judgment gains a rule it never had: how to prove a claim about a **cause**, not
just about behavior. Plus the guard for a constraint that never reaches the
database it was written to protect.

### Added
- **"Diagnosis is a HYPOTHESIS until an artifact names the AGENT"** (`SKILL.md`,
  step 2) — the evidence hierarchy rates claims about *behavior*; nothing rated
  claims about *cause*. Adds the loop **hypothesis → falsifiable prediction →
  command → read**, and the rule that the bar **inverts** for external causes
  (infra, platform, "flaky", third party): no test contradicts an absent culprit,
  so it is never disproven and hardens into folklore. Without an artifact, the
  honest record is *"effect observed, cause unknown"* plus the command that will
  measure it next time. The scar: a "drift daemon" was blamed for months in two
  docs and a skill; `git reflog` showed not one `reset` and `/proc/uptime` showed
  a container minutes old — the sandbox was simply being recycled between turns.
- **`95-schema-constraint-no-migration`** (18th guard, WARN) — a `check` /
  `unique` / `not null` / FK added inside a `create table if not exists` with no
  migration in the same diff. On a database that already has the table, the DDL is
  a no-op: the constraint never runs, while schema-parity and generated-type
  checks all stay green. Passes when the delivery also ships the `alter table`, and
  when the table is genuinely new.
- **Protection levels in step 4** — where a lesson is written decides whether it
  protects anything: 1 memory · 2 prose · 3 a line in this skill · **4 a guard or
  test that fails loud** · **5 impossible by construction**. Only 4 and 5 stand on
  their own; stopping at level 2 is the anti-pattern, with the receipt (a rule
  written in plain words in a project's guidelines, and the mistake happened anyway).
- **Five entries in the excuse-buster table**, each from a shipped failure:
  external-cause blame · `200`-and-a-`grep` as smoke (a 200 can be the error
  boundary; a content grep matches the error page too) · "build passed so it
  renders" (server-render errors pass typecheck AND build, and can be
  intermittent) · **direct writes to production have no diff**, so no guard here can
  see them — a data mutation needs the same proof as a code change · a clean
  production sweep that never touched the route you changed.

### Changed
- Guard count is now **18** across `SKILL.md`, `README.md`, `action.yml` and both
  plugin manifests.
- `tests/run-tests.sh`: **61 → 67** cases (the new guard is proven on three paths —
  it fires on the sin, stays quiet when the migration ships, and stays quiet for a
  brand-new table).

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
