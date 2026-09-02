# Changelog

## 3.0.0 — 2026-09-02

The proof travels with the commit.

### Added

- **`proof.sh` — the evidence, sealed to the commit as a git note.** Everything the gate
  produced was local. The person reviewing the pull request read a description that
  *claimed* a gate ran and had exactly two options: believe it, or re-do the work. That
  is the same trust-me problem this project exists to remove, one level up.

  `seal` bundles the verdict, the blast radius, the claims for this commit, the skeptic
  record and the claim-linked audit segment, hashes each section, and attaches it under
  `refs/notes/proofgate`. It does not change the commit and `--push` sends it with the
  code.

  **What it proves is stated precisely, in the code and in the docs**, because the
  precision is the value: it attests to what the LOCAL gate SAW — these commands ran,
  with these exit codes and output hashes. It does not attest that the local gate was
  honest. So `verify` detects tampering after the seal, `replay` re-runs the recorded
  commands and downgrades the bundle *in the note* when the evidence no longer
  reproduces, and CI re-running the gate is the independent check. The note is what makes
  the two comparable.

  The note deliberately does not survive an amend or rebase (`notes.rewriteRef` is left
  unset): evidence about the old commit is not evidence about the new one, and losing it
  there is correct.

- **`action.yml` verifies the note.** On a `pull_request` the checked-out commit is the
  synthetic merge commit and the note is on the branch head — verifying the wrong sha
  would report `missing` for every PR and teach everyone to ignore the step. A missing
  note does not fail the job by default (teams have commits from before they started
  sealing); **tampering does**, because that is a positive signal rather than an absence.
  `require-proof-note` makes the stricter policy available.

- **`hooks/audit-hook.sh` — a chronology, explicitly not evidence.** A PostToolUse hook is
  not handed a reliable exit code, so every entry stores `exit: null`. A log that
  pretended otherwise would be worse than none: it would look like evidence while being
  unable to distinguish a command that passed from one that failed. Its real job is that
  the edit-guard can be walked around by editing through Bash, and `.git/` is writable —
  neither is preventable, and both leave a trace here. Opt-in, off by default.

- **`tests/acceptance.sh` — the whole protocol, driven in a real repository.** Eighteen
  steps: measure the radius, open a hypothesis, be blocked from editing, record the red
  test, catch a pasted credential at edit time, prove red→green with the same command,
  earn E3 with a marker, pass the gate, be blocked from pushing after the code moves,
  seal, detect a tampered note, replay, be caught forging a ledger row, and render the
  status from the ledger. It caught a defect no unit test could (see Fixed) and it is
  ProofGate's own E3 evidence — for a tool made of shell and git, "the real runtime" is a
  real repository with a real remote.

- **The SKILL is now a protocol, not only a checkpoint**: RECALL → HYPOTHESIZE →
  EXPERIMENT → IMPLEMENT → PROVE → SEAL → REPORT, each phase naming the command or hook
  that anchors it. The gate at the end was always half the tool — by the time a status is
  being written, the expensive mistakes have already happened.

### Fixed

- **A claim survived an uncommitted edit — in the display, at least.** Claims matched on
  the HEAD sha *or* the content id, so after recording evidence and then editing a file
  without committing, the gate still printed `✅ proof-level: central claim at E3` for a
  run that happened against different code. Nothing false could ship — the `git-committed`
  FAIL blocks the delivery in exactly that window — but "it fails for another reason
  anyway" is not a defence for printing a green line that is not true, in the one place
  whose entire job is not doing that. Found by running the gate on this very documentation
  pass.

  Matching on **content only** fixed the display and immediately broke something better:
  the acceptance run went from 18/18 to 16/18. A **red test is evidence about the code
  BEFORE the fix** — that is its entire purpose — so its content id can never match the
  fixed tree, and the strict rule deleted the counter-proof from the delivery it proves.
  Worse, `list` stopped showing the red row, leaving no id to pass to `--same-as`: the
  red→green workflow the tool insists on became unperformable with the tool.

  So the rule is exact rather than merely strict. A red row is admitted when a **current
  green row references it** — the pair is admitted together or not at all. And `list`
  became a browser that *labels* (`*` = still describes this code) instead of hiding,
  because you cannot reference an id you cannot see. `achieved` and `render` stay strict;
  they are what gates. Two more tests pin the pair rule and the labelling.

- **`edit-notice` was silent on macOS.** A repo created under `mktemp -d` lives at
  `/var/folders/...` while `git rev-parse --show-toplevel` resolves the symlink to
  `/private/var/folders/...`, so stripping the root prefix from the edited file's path
  left it ABSOLUTE. `memory.sh recall` matched nothing (anchors are repo-relative) and
  the notice came back empty — the failure mode being *no output*, which is
  indistinguishable from "nothing to say". Paths are now compared physically
  (`pwd -P` on both sides), and a file resolving outside the repository exits early
  instead of guessing.

  Worth naming twice: the live-guard half of the same hook appeared to work, because an
  absolute pathspec made it scan the whole working tree instead of the edited file. It
  produced the right answer for the wrong reason, which is the kind of pass that hides a
  defect rather than proving its absence.

  Caught by the macOS CI matrix — the exact platform this delivery's own status block
  declared as NOT TESTED. The regression test reproduces the condition with a symlinked
  repo root, so it is pinned on every platform rather than only on the one that found it.

- **Committing orphaned the evidence.** Claims were keyed to the HEAD sha at the moment
  they were recorded, so `git commit` silently detached every claim made before it. The
  natural order of work — do it, prove it, commit it, gate it — produced a delivery whose
  status rendered `VERIFIED: NOTHING` with a full ledger sitting on disk. The only
  workflow that worked was recording every claim *after* the final commit and again after
  every amend, which is exactly the kind of ceremony people stop performing.

  Evidence is now bound to the **code** it describes (`pg_content_id`: a map of path →
  the blob actually there), not to the commit that happens to carry it. It survives the
  commit that packages the same bytes and dies the moment the code changes — which is the
  property worth keeping, and the one the SKILL calls *"green WHEN?"*.

  **Found by the end-to-end run, not by a unit test**, against a suite that was entirely
  green: every piece behaved exactly as specified, and the path through them did not
  work. That is why `tests/acceptance.sh` now exists and runs in CI.

- **`replay` re-ran a different command from the one it was checking.** The ledger stores
  commands JSON-escaped, and replay pulled them out with `grep` and executed the escaped
  form — so `printf 'calc=3\n'` ran with a literal backslash-n. That is the worst
  possible defect in the component whose entire job is confirming that recorded evidence
  still reproduces: it can fail honest evidence and it can pass evidence that no longer
  holds.

  The obvious fix is also wrong, and wrong in a way that looks right: a few global
  substitutions reversing the escape cannot invert it, because `\\n` — an escaped
  backslash followed by an `n` — matches the newline rule first. Undoing an escape needs
  a single left-to-right scan, which is what a parser does. `pg_json_field` now reads any
  value that will be EXECUTED through the same jq → node → python3 chain the config uses,
  and a test pins exactly that escaping.

## 2.12.0 — 2026-09-02

The skeptic gets a slice; the guards get a scorecard.

### Added

- **`skeptic.sh` — refutations held to the standard they impose.** The adversarial pass
  had exactly the weakness it was built to attack. A skeptic that writes *"REFUTED: this
  probably breaks under concurrency"* has produced an **E0 claim** — words, no run — and
  because it sounds rigorous, it is trusted more than the claim it just refuted.
  Skepticism with nothing behind it is not the opposite of overclaiming; it is the same
  failure wearing the other costume, and it is the more expensive one, because it sends
  people to fix what was never broken and teaches them to discount the next finding.

  So the rule is symmetric. Every REFUTED carries a command, and the recorder **re-runs
  it**: reproduces → the refutation stands and opens a lesson; exits 0, or no command →
  downgraded to UNPROVEN, with the original verdict kept in the record. A CONFIRMED is
  capped at the level the claims ledger recorded, for the mirror-image reason — agreement
  is not a run, and cannot turn E2 evidence into E3.

- **A panel, sized to the blast radius.** `intent-skeptic` asks the question no other
  check asks — *is this the thing that was requested?* Correct code that solves a
  different problem passes every other gate and is still a failure, usually discovered by
  the person who asked. `security-skeptic` runs only at L3, where the cost of a defect is
  not proportional to the size of the diff: a one-character permission change is a breach,
  a float where money should be an integer is a silent unrefundable loss. Ordinary review
  allocates attention by lines changed, which is exactly the wrong allocation there.

  Nobody runs at L1. Ceremony for a README edit teaches everyone that the ceremony is
  noise, which is how the whole apparatus gets skipped on the day it matters.

- **`impact.sh --slice`** — the scope the panel reads: the diff, the first-degree callers
  of every changed symbol, the tests that touch them. A skeptic handed the whole
  repository reads none of it; one handed the author's summary audits the summary.

- **`99-skeptic-required`** — WARN when an L3 change has no adversarial pass for the
  CURRENT commit (a pass recorded before the code moved is not a pass), or when the
  security-skeptic did not run. FAIL when a reproducing refutation is still open: that is
  a command that fails today, not an opinion. `requireSkeptic` makes the whole guard a
  FAIL for teams that have wired the panel up.

- **Guard calibration (`verify.sh --calibration`).** Every guard trades signal against
  noise and the trade is invisible from inside one run. Three counters make it visible —
  `fired`, `allowed` (suppressed via `proofgate-allow`, `.proofgateignore`, or a severity
  override) and `scars` (a recorded incident credited this guard as what would have caught
  it). High allowed with zero scars is the demotion signal.

  It **reports and never applies**. A tool that quietly turned its own checks off after
  enough suppressions would be automating precisely the erosion it exists to measure;
  demoting a guard is a decision for a person, made with the table in front of them. A
  test asserts that running the report leaves `proofgate.json` byte-identical.

### Fixed

- **The calibration report rendered an empty table.** It split the JSON on quote
  characters and matched nothing, so the report printed headers and no rows — which reads
  as "no guard has a problem". A report that silently shows nothing is worse than no
  report at all.

## 2.11.0 — 2026-09-02

Experiments where they cannot hurt; prototypes that cannot hide.

### Added

- **`experiment.sh` — every hypothesis gets its own git worktree.** Testing an idea means
  changing something, running, and changing it back, and *changing it back* is where this
  goes wrong. Three experiments in a row leave a working tree nobody can characterise:
  some edits reverted, some not, one half-applied — and the next result describes a state
  that was never designed. The classic ending is a "fix" that works only because of a
  leftover from experiment two.

  Each run is isolated and cleaned up, and the result is recorded against the hypothesis
  **by the script**, not typed afterwards by whoever remembers what happened — the same
  rule as the claims ledger, for the same reason. `--dirty` carries uncommitted work in,
  because an experiment about the change you are making would otherwise silently run
  against the code as it was before you made it.

  `--parallel` is what the isolation buys: independent ideas can be tested at once.
  Sequential testing was never a requirement, only a consequence of having one working
  tree. `--in-place` exists for what a worktree cannot serve, and is honest about the
  cost — the tree is hashed before and after, and a mutation is recorded as
  `tree-mutated`, because a result from a run that altered the tree describes a state
  that no longer exists.

  It never closes the hypothesis for you. An experiment produces an observation; what it
  MEANS is the judgment this tool refuses to fake.

- **Prototype mode (`mode.sh`, `hooks/prompt-hook.sh`) — real, and impossible to forget.**
  Sometimes you are exploring and the full ceremony is genuinely the wrong price. A tool
  that refuses to admit that gets bypassed wholesale, and a bypassed gate protects
  nothing at all. So the mode is real: the edit-guard and stop-guard stand down.

  The danger was never the mode; it is forgetting you are in it and then reporting relaxed
  work as if it had been gated. So it is loud in four places at once — a banner on **every
  prompt**, a line at every session start including after a compaction, `mode` in the
  verdict, and claims capped at E1 with the status block prefixed `UNVERIFIED PROTOTYPE`.
  Repetition is the feature here; everywhere else in this repo it would be a defect.

  Two things it deliberately does not do. **The push-guard is not relaxed** — exploring
  freely is fine, shipping unproven work is the one thing the tool exists to stop, and a
  mode that turned that off would be the bypass with a friendlier name. And it **does not
  expire on its own**: an auto-expiry would end the mode quietly, at a moment nobody
  observed, making the status of any given piece of work a question of timing.

### Fixed

- **Parallel experiments collided.** The worktree path was composed from the clock and
  `$$`, and two jobs started in the same second share the parent's PID — so the second
  worktree failed to create and its experiment was lost. Uniqueness has to be atomic
  (`mktemp`), not merely likely. Three concurrent jobs are now a test.

## 2.10.0 — 2026-09-02

Memory anchored to code, not to prose.

### Added

- **`memory.sh` — project memory that can be shown to have gone stale.** The obvious
  version of this feature is a notes file, and the obvious version is worse than nothing.
  A note that was true in March is indistinguishable from one that is true now, and the
  reader — usually a model with no way to check — treats both as fact. The failure mode
  is not forgetting. It is remembering something that stopped being true, confidently,
  and building on it.

  Every fact is ANCHORED to a file plus the blob hash that file had when it was recorded,
  and staleness is **derived at read time, never stored**. That difference does more work
  than it looks: there is nothing to keep in sync so nothing can drift out of sync, no
  write on the hot path of editing, and no field an agent can flip to make an
  inconvenient fact look current. It is the SKILL's own level 5 — derive from a single
  source and divergence becomes impossible rather than discouraged.

  Classes expire differently because they mean different things: a **decision** holds
  until revoked, an **inference** expires when the code it read has moved, an
  **incident** never expires. An *agent's* `decision` expires like the inference it
  really is (`memory.agentDecisionsExpire`) — otherwise an agent makes its own conclusion
  permanent policy by choosing a label.

- **The lesson loop, closed.** The SKILL's ladder says only a guard or a test stands on
  its own, and that stopping at "prose in a doc" is the anti-pattern. Now a recorded
  incident OPENS a lesson, and `98-unlearned-lessons` says so on every run until
  something at level 4 answers it — a guard carrying `proofgate-lesson: <id>`, a
  regression test, or an explicit `--resolves`. A comment in a README deliberately does
  not count, and a test pins that: it is level 2 wearing level 4's clothes, which is the
  exact confusion the ladder exists to name.

- **`97-memory-stale`** — WARN only when a stale fact is anchored to a file *in this
  diff*. That restriction is the feature: warning about every stale fact in the
  repository on every run is wallpaper within a week, and wallpaper is how a gate stops
  being read.

- **`hooks/edit-notice.sh` (PostToolUse) — the guards, brought forward to the moment of
  the edit.** The gate is deliberately a gate: it judges the finished diff. That timing
  is right for a verdict and wrong for feedback. A pasted credential, a
  `rejectUnauthorized: false` added to make a cert error go away, a `.only` left on a
  test — each is an undo in the ten seconds after writing it and a rotation or a rewrite
  by the time the gate runs. The guards are `git diff | grep`; there was never a reason
  for that answer to wait. It also recalls any memory anchored to the file being edited.
  Never blocks, opt-in per half (`liveGuards`, and a memory file existing).

- **`pg_added_lines`** in lib.sh: the added-lines view three guards had each hand-rolled.
  Sharing it is not tidiness — the hand-rolled copies silently opted those guards out of
  live mode, so `secrets`, `pii-logging` and `debug-leftovers` could not run at edit time
  at all. Live coverage is partial by construction (guards that build their own range see
  an empty one) and the code says so: silence there means "nothing this path can see",
  never "clean".

### Fixed

- **`install.sh --uninstall` deleted the team's project memory.** It did `rm -rf` on
  `.proofgate/`, which now holds committed content — `memory.jsonl`, `lessons.jsonl`,
  sometimes years of it — next to the disposable vendored machinery. Removing a tool
  should never take institutional knowledge with it. Now preserved, announced, and tested.

## 2.9.0 — 2026-09-02

A hypothesis outlives the context window.

### Added

- **`hypothesis.sh` — an append-only ledger of what was tried and what it ruled out.**
  The SKILL has always taught the loop: mechanism, falsifiable prediction, the command
  that reveals the mark, read the result. What it could not do is make the RESULT
  survive. A long investigation produces refutations — *"checked the reflog, no reset"*,
  *"there is no cache step in this pipeline at all"* — and those are the most valuable
  thing it produces, because each one closes a branch of the search space. Then the
  context is compacted. The summary keeps the code and the goal and drops the negative
  results, because they read like nothing happened. The next turn proposes the dead
  explanation again, and it is *more* convincing the second time, since nothing visible
  contradicts it.

  Refutations now live on disk. Silence is recorded as the observation it is (`the
  predicted mark is ABSENT`), `confirm` and `refute` both require evidence, and
  re-proposing an already-refuted idea is refused with the date and what killed it.
  Re-wording still gets through — that limit is stated in the file rather than implied
  away, and re-injection is what covers it.

- **`hooks/session-hook.sh` (SessionStart: startup · resume · compact)** re-injects the
  open hypotheses, the refuted ones, unresolved lessons and any mode left on. This is
  the half that makes the ledger matter: state on disk that nobody thinks to read is
  not memory.

- **Strike escalation — the SKILL's "the bar inverts for external causes", mechanised.**
  Refutations are counted per `--symptom`. Once the same symptom has survived two
  explanations (`hypothesis.strikeThreshold`), the next hypothesis on it is marked
  `escalated`, and `impact.sh` turns that into `skeptic_required`. The third guess about
  a stubborn symptom is precisely where an invented culprit gets written down and
  hardens into folklore, and "effect observed, cause unknown" is the better record.

- **`hooks/edit-guard.sh` (PreToolUse: Edit|Write|MultiEdit, opt-in `editGuard`)** —
  the counter-proof, enforced first. With an open bugfix hypothesis and no red-test claim
  behind it, editing a non-test source file is blocked, with the exact command to run.
  It exists because *first* is the part a prompt cannot enforce: at the moment of
  editing, the intention to write the test afterwards is completely sincere. A suite that
  was green before the edit and green after it proved that nothing else broke — not that
  the bug is gone. Off by default, and honest about its limit: an edit made through Bash
  never reaches a PreToolUse hook, so this raises the cost of skipping the counter-proof,
  it does not make skipping impossible.

- **`guards.d/93-hypothesis-required.sh`** — WARN when a fix branch carries no hypothesis
  at all. A cause that is never written down is never falsified; it just gets implemented,
  and the root-cause section ends up written backwards from the change that was made.

- **`/proofgate:preflight`** — measure the radius, recall what the project already knows
  about these files, name the E3 observation, open the hypothesis. All four are things
  that are impossible or dishonest to do afterwards.

### Fixed

- **Hooks blocked with no reason attached — since 2.0.** Every hook wraps its body in
  `{ ... } 2>/dev/null` so a broken guard can never wedge the agent. That same redirect
  ate the block message. The contract says "exit 2 blocks and feeds stderr back to the
  agent"; what the agent actually received was a bare refusal and no explanation — the
  exact silent failure this project exists to forbid, shipped in the component whose job
  is to forbid it. Deliberate output now goes to a descriptor dup'd before the wrapper,
  and a test asserts the message reaches stderr.

- **Hooks silently did nothing when installed as a plugin without vendoring.** They
  looked for `lib.sh` in the repo's own source or in `.proofgate/`, and a repo that has
  neither — the normal case for `/plugin marketplace add` — left `cfg` undefined, so
  every hook exited 0. A guard that quietly does nothing is worse than no guard, because
  the repo believes it is protected. All four hooks now fall back to the copy that ships
  inside the plugin.

- **A `pipefail` + `grep -q` trap in the test suite.** `producer | grep -q x` reports
  failure even on a match: grep exits at the first hit, the producer dies of SIGPIPE, and
  `pipefail` promotes that to the pipeline's status. Three passing checks looked like
  failures. Captured first, then matched — noted in the tests, because a check that
  cries wolf is how people learn to ignore red.

## 2.8.0 — 2026-09-02

The report is rendered, not written.

### Added

- **`claim.sh` — a claims ledger where the evidence level is EARNED, not typed.** The
  judgment gate has always said a runtime claim is done only at E3. It also, until now,
  let an agent that ran nothing type `VERIFIED (E3): the checkout flow works` — every
  word free. The evidence hierarchy, the banned-language list, the excuse-buster table:
  all of it rested on the author volunteering an honest level at exactly the moment they
  are least inclined to. That is not a discipline problem, it is a missing mechanism.

  `claim.sh add --run "<cmd>"` **executes the command**, records the exit code, a hash of
  the output and the duration, and appends a hash-chained row. There is no code path that
  writes a level above E0 without this script having run something. Four refusals close
  the obvious ways around it:

  - `--run "true"`, `npm test || true`, `pytest ; exit 0` — a command whose exit status
    cannot change proves nothing. (A real pipeline like `cat x | grep -q y` is fine; the
    check distinguishes a simple constant-status command and a success-forcing suffix
    from a pipeline that can actually go red.)
  - **E3/E4 require `--expect`** — a marker that must appear in the output. "It returned
    200" is compatible with the old build still being live, which is why the SKILL has
    always asked for a marker unique to the NEW version. Now it is mechanical.
  - **`--kind red-test` is refused if the command passes.** A test that was never red has
    never shown it can see the bug.
  - **`--kind green-test` must re-run the same command as its `--same-as` red row.** A
    different command passing proves a different thing.

  A run that fails, or a marker that does not appear, still writes the row — at **E0**,
  with the reason recorded. That row is the valuable one: it is how "not verified"
  survives into the status instead of being smoothed over.

- **`claim.sh render` — the status block is GENERATED.** It is assembled from the verdict,
  the blast radius and the ledger, so every line traces to something that ran. The SKILL
  and the templates now say plainly: a status you compose by hand is E0 by construction,
  because nothing produced it. An empty ledger renders as `VERIFIED: NOTHING`, which is
  the delivery's real state, not a formatting problem.

- **`proof-level`: required vs achieved, with three distinct outcomes.** The blast radius
  says what this change owes; the ledger says what was earned. `proven` · `unproven` (the
  evidence is missing and producible here) · `cannot_prove` (it is impossible here — no
  e2e command, no `smoke[]`, no dev server to curl).

  Keeping the third separate is the whole point. `cannot_prove` is a fact about the
  machine, not a defect in the diff: nothing the author writes makes an absent runtime
  appear. So it is a NOTE by default and never fails `--strict` — a rule that failed
  every delivery on every box without an e2e setup would not be rigour, it would be the
  fastest possible route to `alias verify=true`. Repos that want it enforced set
  `requireProof: true`, and then the push-guard and stop-guard block with the missing
  capability named.

- **Hash-chained ledgers + the `ledger-chain` check.** Every row carries the hash of the
  row before it, so a line appended or edited by hand — the agent writing its own
  evidence — breaks the chain and FAILS the gate. Stated honestly in the code and here:
  this is tamper-**evident**, not tamper-proof. Anything with a shell can recompute the
  whole chain. What it removes is the cheap, deniable edit, and it makes the expensive
  one visible.

- **`/proofgate:claim` and `/proofgate:report`**, plus `requireProof` in the config
  reference.

## 2.7.0 — 2026-09-02

The gate learns how big the change is.

### Added

- **`impact.sh` — the blast radius, computed before anything is judged.** Every run now
  starts by measuring what the diff can break: the changed files, the symbols inside the
  changed line ranges, their first-degree callers, the tests that touch those symbols,
  and the direct importers. The measurement lands in `.git/proofgate-impact.json` and
  drives everything downstream.

  The scar is not a bug report — it is the shape of every gate that gets switched off.
  A gate with one fixed price teaches the team that its ceremony is noise, because the
  README edit and the migration to the payments table pay exactly the same toll. The
  cheapest way to make ProofGate ignorable was to keep charging full price for a typo.
  So the price is now proportional, and *proportional to what* is computed rather than
  felt:

  | Class | What it is | Evidence it owes |
  |---|---|---|
  | **L1** | docs, tests, config only | E1 |
  | **L2** | source with callers | **E3** |
  | **L3** | auth · money · migrations · crypto · permissions | **E3 + a mandatory adversarial pass** |

  Two properties keep that from being theater. The range is the **whole branch plus the
  working tree** — `merge-base..HEAD` *and* uncommitted edits — because a radius computed
  on the tip would be gamed by the oldest trick there is: put the migration in commit one,
  put a docs change in commit three, gate commit three. And "sensitive" is decided by
  **content as well as path**, so money math filed under `utils/helpers.ts` is still L3.

- **Declared degradation, everywhere.** With Universal Ctags on PATH, symbols come from a
  real symbol table and the output says `navigation_confidence: high`. Without it — or with
  the Exuberant ctags macOS ships — callers come from a word-boundary grep, confidence says
  `low`, and a `degradations` list names exactly what could not be done. This matters more
  than the feature it qualifies: an empty caller list from a low-confidence run means *"I
  found none"*, not *"there are none"*, and a tool that lets you confuse those two is the
  thing this project exists to stop. `impact.backendCmd` is the seam for a real language
  server: a command that reads changed paths on stdin and prints symbols and callers back.
  Point it at an LSP client and confidence becomes `high` without ProofGate pretending to
  speak JSON-RPC.

- **`max_achievable_level` — the difference between unproven and unprovable.** On a machine
  with no e2e command, no `smoke[]`, and no dev server to curl, E3 cannot be produced at
  all. Demanding it anyway would fail every delivery for a reason the author cannot fix,
  which is how a gate earns an alias in someone's shell profile. The verdict now reports
  what is *reachable* here, so "not proven" and "not provable on this box" stop being the
  same sentence.

- **Verdict v2, strictly additive.** `schemaVersion` is 2 and the document carries the
  impact summary, `required_level`, `max_achievable_level` and `degradations`. The v1
  prefix is byte-identical through `"pass"`, the file stays on one line, and it contains
  **exactly one** `"sha":` and one `"pass":` — nested objects say `head_sha`/`base_sha`
  instead. That is not fussiness: four readers parse this file with `sed`/`grep`, and one
  of them is the pre-push hook `install.sh` already wrote into users' repositories, which
  never updates itself. Their `sed` is greedy — a second `"sha"` anywhere in the document
  would silently win. A test now pins the invariant.

- **`caso_tool`** in the test harness: `caso_verify` generalized to any script, so every
  tool from here on gets the same real fixture (real repo, real remote, real base). It
  runs the tool with stdin closed — a tool that reads stdin by accident should fail a
  test, not hang the suite.

- **A portability test and a documentation test.** CI runs macOS (bash 3.2, BSD userland),
  where `declare -A`, `mapfile`, `sed -i`, `date -d` and friends fail on a box where the
  author saw green — the worst kind of failure. A grep over every shipped script now
  catches them locally. And the guard count, written by hand in five files, was already
  wrong: the docs said 18 while `guards.d` held 19. A number a human maintains drifts, so
  it is asserted against `ls guards.d` instead.

- **`self-gate` CI job.** ProofGate runs its own gate on its own diff, with Universal
  Ctags installed so the high-confidence path is exercised rather than assumed. A tool
  that cannot pass the standard it sells is selling theater.

### Fixed

- **Guard count drift in `SKILL.md`, `plugin.json`, `marketplace.json` and `action.yml`**
  (18 → 19), found by the new test rather than by a reader.

- **`.proofgateignore` is no longer scanned by the guards.** Found by the self-gate on
  this very release, and it is an ouroboros worth naming: suppressing a finding requires
  writing the offending pattern into the ignore file — that is how you say *which*
  finding — and the guards then flagged the suppression file. Every escape hatch that
  forces you to quote what you are escaping has this bug; ProofGate's own control files
  are now excluded like the rest of its source.

- **`sourceless-diff` now reads the impact measurement instead of re-deriving it.**
  The engine had two different rules for "how much source is in this diff" — impact's
  file classification, and a narrower path-glob-plus-extension heuristic in the
  blind-gate check. On this repository they disagreed completely: impact reported 17
  source files while the check announced the guards had been looking at nothing. A
  warning that contradicts the line printed four seconds earlier teaches people to
  ignore both. One measurement, read by both; the old heuristic survives only as the
  fallback for `--no-impact` and for vendored copies without `impact.sh`.

- **The sensitive-term scan reads source files only.** Also found by the self-gate: a
  README, a changelog and an annotated config example that DESCRIBE the term list were
  escalating this release to L3 for the crime of documenting what L3 means. Terms are a
  signal about code, not about prose.

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
