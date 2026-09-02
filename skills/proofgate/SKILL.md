---
name: proofgate
description: Acceptance gate to run BEFORE declaring any delivery "done" (feature, bugfix, release, deploy, PR merge-ready), and a protocol to run DURING it. Measures the change's blast radius and charges evidence in proportion (L1 docs → E1, source → E3, auth/money/migrations → E3 plus a mandatory adversarial pass). Records claims by RUNNING the command that proves them, so a level cannot be typed; keeps hypotheses and their refutations across context compaction; anchors project memory to code so stale facts announce themselves; and seals the evidence to the commit as a git note a reviewer can verify. Also use when a bug reappears, a fix has failed twice, a status is about to be written, or you are about to say "done".
---

# ProofGate — acceptance with EVIDENCE, not hope

This gate exists because of a pattern every developer working with AI agents knows:
**"Done!" — and then the blank screen.** Compiled ≠ works. Deployed ≠ verified.
Plausible ≠ proven.

**Golden rule: a checklist without evidence is theater.** Every item below is
answered with a COMMAND THAT RAN, a LINK, a NUMBER — never with "I believe so."

## The protocol: RECALL → HYPOTHESIZE → EXPERIMENT → IMPLEMENT → PROVE → SEAL → REPORT

The gate used to be a checkpoint at the end. That was always half the tool: by the time
you are writing a status, the expensive mistakes — investigating an explanation that was
already ruled out, editing before establishing the bug is reachable, trusting a note that
stopped being true — have already been made. Each phase below has a **mechanical anchor**:
a command or a hook, not a reminder.

| Phase | What it prevents | Anchor |
|---|---|---|
| **RECALL** | re-deriving what the project already knows; re-running a dead investigation | `/proofgate:preflight` · `memory.sh recall --changed` · `hypothesis.sh brief` · SessionStart hook |
| **HYPOTHESIZE** | a cause that is implemented instead of falsified | `hypothesis.sh open --kind bugfix --symptom …` |
| **EXPERIMENT** | a result that describes a state nobody designed | `experiment.sh <id> -- <cmd>` (own worktree) |
| **IMPLEMENT** | the fix that fixed nothing | `editGuard` — no source edit while a bugfix hypothesis has no RED test |
| **PROVE** | a level that was typed rather than earned | `claim.sh add --run` · `verify.sh` · the skeptic panel |
| **SEAL** | "trust me, the gate ran" | `proof.sh seal --push` → a git note the reviewer can verify |
| **REPORT** | a status written by the same process that wrote the code | `claim.sh render` — generated, never composed |

Two of those are worth stating as rules, because they are the ones under pressure at the
moment they apply:

- **The counter-proof comes first.** A suite that was green before your edit and green
  after it has proven that nothing else broke — not that the bug is gone.
- **The status is rendered, not written.** A block you compose by hand is E0 by
  construction, because nothing produced it.

### The commands behind each phase

| Command | Use it when |
|---|---|
| `/proofgate:preflight` | starting anything — measures the radius, recalls what the project knows about these files, opens the hypothesis |
| `/proofgate:claim` | you have something to assert — it RUNS the command and records the exit code |
| `/proofgate:experiment` | testing an idea — its own worktree, several at once, nothing left behind |
| `/proofgate:gate` | before declaring done — radius → mechanical → skeptic panel → seal → render |
| `/proofgate:report` | writing the status — it is generated, and a typed one is E0 |
| `/proofgate:seal` | the evidence should travel with the commit |
| `/proofgate:prototype` | exploring, and the full ceremony is genuinely the wrong price |
| `/proofgate:calibration` | a guard feels like noise — see whether it has ever earned its keep |

Vendored (`install.sh`) the same tools live in `.proofgate/`; in-repo they are under
`skills/proofgate/scripts/`.

## The 5-step gate function (run it before ANY status claim)

Before you type "done / fixed / it works / tests pass", run this in your head —
skipping a step is not verifying, it is guessing:

1. **IDENTIFY** the exact command (or observation) that would prove the claim.
2. **RUN** it, freshly and completely — not a remembered result from ten edits ago.
3. **READ** the full output: exit code, failure count, the actual lines.
4. **VERIFY** the output supports the specific claim you're about to make.
5. **THEN** claim — quoting the evidence.

## Step 1 — the MECHANICAL gate (automated)

```sh
bash scripts/verify.sh                              # fast gate (no build)
bash scripts/verify.sh --build                      # include the build (pre-release)
bash scripts/verify.sh --strict                     # warnings become failures
bash scripts/verify.sh --smoke                      # run the production smoke checks
bash scripts/verify.sh --json                       # verdict as JSON on stdout
bash scripts/verify.sh --report proofgate-report.md # write a markdown artifact
```

**It measures the blast radius first.** Before a single command runs, `impact.sh`
computes what the diff can break — over the WHOLE branch plus your working tree, so
splitting the risky part into an earlier commit changes nothing — and classifies it:
**L1** (docs/tests/config) · **L2** (source with callers) · **L3** (auth, money,
migrations, crypto, permissions). That class sets the evidence this delivery owes:
L1 → E1, everything else → **E3**, and L3 additionally requires the adversarial pass.
The line it prints also names the navigation backend and its confidence, plus anything
it could NOT do (`declared: no-ctags …`) — a gate that quietly knows less than it
implies is the failure this whole skill exists to stop.

Auto-detects your stack (pnpm/npm/yarn/bun, Cargo, Go, Python, Gradle/Maven, .NET,
Ruby, PHP, Elixir, Deno) and runs what the machine checks better than judgment:
typecheck / lint / tests (/ build) actually green; working tree committed; **19
diff guards** (secrets, PII-in-logs, TLS-off, merge markers, silenced tests/types,
money-as-float, hand-built SQL, machine paths, dependency-lockfile drift,
un-migrated schema constraints, …).
Every full run writes a **SHA-bound verdict** to `.git/proofgate-verdict.json`.

**Any ❌ = the delivery is NOT done.** Every ⚠️ demands a written justification —
never silent dismissal. False positive? `proofgate-allow` on the line, a
`.proofgateignore` fingerprint, or `skip`/`severity` in `proofgate.json`.

## Step 2 — the JUDGMENT gate (one by one, with proof)

### The evidence hierarchy — where does your central claim actually sit?

**Record it, do not assert it.** The level of a claim is now something a command
earns, not something you type:

```sh
# the bug reproduces — BEFORE the fix (refused if the command passes)
bash scripts/claim.sh add --kind red-test --run "<the failing test>"
# the same command now passes
bash scripts/claim.sh add --kind green-test --same-as <red-id> --run "<the SAME test>"
# the central runtime claim
bash scripts/claim.sh add --claim "checkout completes" --level E3 \
  --run "curl -s localhost:3000/health" --expect '"build":"<new sha>"'
# what you did NOT verify — declared, not omitted
bash scripts/claim.sh add --kind gap --claim "the concurrent path is not exercised"
```

`claim.sh` RUNS the command, records the exit code and a hash of the output, and writes
a hash-chained row. A level above E0 has no code path that does not go through a real
run. `--expect` is mandatory at E3+ because "it returned 200" is compatible with the old
build still being live. A run that fails, or a marker that does not appear, still writes
the row — at E0, with the reason. **That** row is the valuable one.



| Level | Name | What it proves |
|------|------|----------------|
| **E0** | believed / asserted | nothing — it's just words |
| **E1** | static | it parses / typechecks / lints. Not that it works. |
| **E2** | automated test | a test exercises the changed behavior and passes |
| **E3** | exercised end-to-end | the real flow was DRIVEN on the real runtime and the right result OBSERVED (curl the running server, click the UI, run the emulator) |
| **E4** | observed in production | the deployed system was seen doing it |

**A claim about runtime behavior ("the bug is fixed", "the feature works") is DONE
only at E3 or higher.** "It compiles" (E1) and "a unit test passes" (E2) are
necessary, not sufficient. State the level of your central claim explicitly.

### Diagnosis is a HYPOTHESIS until an artifact names the AGENT

The hierarchy above rates claims about *behavior* ("the screen works"). Claims about
*cause* ("X is what broke it") need their own rule — and that gap hid a wrong diagnosis
for **months** in the project this gate was born in. The symptom was real and seen many
times: a working tree kept reverting to an older state. The cause was fiction — a
"drift daemon" that was written into two docs and a skill, and that nobody ever went
looking for. Two commands eventually ended the story: `git reflog` showed **not one**
`reset`, and `/proc/uptime` showed a container minutes old. The real cause was
mundane — the sandbox is recycled between turns, so a *new* container comes up with
the repo at its image state. Nothing was attacking anything.

**Observing an effect is not identifying an agent.** Before you write a cause anywhere
durable (status, PR, postmortem, known-issues doc), run the loop:

**Write it down, or it cannot be killed.** The loop below is now backed by a ledger
(`scripts/hypothesis.sh`), for one reason: refutations do not survive a compaction. The
summary keeps the code and drops "I checked the reflog, there was no reset" — because a
negative result reads like nothing happened — and the dead explanation comes back, more
convincing the second time because nothing visible contradicts it. The ledger lives on
disk and a SessionStart hook re-injects it after every compaction.

1. **Hypothesis** — the mechanism, in one sentence. *"A process runs `git reset` on the repo."*
   → `hypothesis.sh open --kind bugfix --symptom <tag> --hypothesis "..."`
2. **Falsifiable prediction** — if that were true, what MUST exist? *"A `reset` in the
   reflog; a process in `ps`; an entry in a log, cron or hook."*
3. **Command** — the one that reveals that mark. Run it.
4. **Read** — is the mark there? If NOT, the hypothesis is dead. Don't patch it. Replace it.
   → `hypothesis.sh refute <id> --run "<cmd>"` records what was seen — including silence,
   which is the whole point: "the predicted mark is ABSENT" is the result that closes a
   branch of the search. Re-proposing that exact idea later is refused.

**The bar inverting for external causes is now mechanical.** Refutations are counted per
`--symptom`. Once the same symptom has survived two explanations, the next hypothesis on
it is marked `escalated`, and the gate requires an adversarial pass before "done" — the
third guess about a stubborn symptom is exactly where an invented culprit gets written
down and hardens into folklore.

**And the counter-proof comes first.** With `editGuard: true`, an open bugfix hypothesis
with no failing test recorded blocks edits to source files. Not because you would forget
— because at the moment of editing, the intention to write the test afterwards is
completely sincere, and a suite that was green before your edit and green after it has
proven that nothing else broke, not that the bug is gone.

**The bar INVERTS for external causes.** When blame lands outside your own code — infra,
platform, "flaky test", a third party, the environment — the standard goes UP, not down.
No test contradicts an absent culprit, so it is never disproven on its own; it hardens
into folklore, and future decisions quietly orbit it. Without an artifact naming the
agent, the honest record is **"effect observed; cause unknown"** plus the command that
will measure it next time. That is far more useful than an invented culprit, because it
keeps the question open.

### Answer in writing (status report or PR body). No proof = open item.

1. **Root cause with evidence.** If this fixes a bug: WHAT is the real cause, WHERE
   is the evidence (error event, log, local repro, query, curl), and in WHICH LAYER
   does the failure live (frontend/backend/native/infra)? A try/catch in one layer
   doesn't catch a crash in another. Then the **counter-proof**: what would you
   expect to see if this fix were WRONG — and did you check it's absent?
   If the cause is EXTERNAL, apply the inverted bar above — naming an absent culprit
   is the mistake that survived months here.
2. **VERIFIED ≠ hoped.** List EXPLICITLY (a) what was exercised and at what level,
   and (b) what was NOT + how it will be. If list (a) tops out below E3 for a
   runtime claim, the delivery isn't done — it's a hypothesis.
3. **Production path traced.** Depends on env/storage/migration/config in prod? The
   post-deploy smoke of the REAL flow is done or scheduled, asserting a marker
   **unique to the NEW version** (not a string present in the old one too). Test the
   authenticated and the negative path, not just the happy anonymous one.
4. **Cross-checked with what's already known.** Re-read your project's known-issues
   doc BEFORE declaring. Rediscovering a documented problem via a user complaint is
   the maximum embarrassment.
5. **Failed twice on the same thing? STOP** — don't hammer a third time. Step back,
   RESEARCH (official docs, source, search), change the APPROACH, record the change.
6. **UI changed? Prove it on the real target** (deployed page screenshot, emulator
   run) — with your own eyes, not assumed.
7. **Touched infra/config? Re-check the obvious** — app name, permissions, prod env,
   schema parity. The trivial detail is the one that humiliates.
8. **Sensitive data on the new path** — PII in any payload/log? Adversarial test
   asserting it never leaks?
9. **Brutally honest status** — VERIFIED (with the proof) · NOT TESTED (with the why
   and how) · PARTIAL (what's missing). An inflated status rots trust worse than a bug.

### Mutation — the only proof that a test can see

```sh
node skills/proofgate/scripts/mutate.mjs <source-file> -- <test command...> < mutations.jsonl
```

Each stdin line is `{"name": "...", "from": "<literal>", "to": "<literal>"}`. The runner
requires a **green baseline** first (otherwise "killed" may just be an unrelated breakage),
requires `from` to occur **exactly once** (a near-miss edits the wrong place and reports a
confident, meaningless result), restores the file on any exit, and returns **1 with the list
of survivors**. Empty input is exit **2** — a run that mutated nothing must never be mistaken
for a run where nothing survived.

Reach for it whenever a suite passes on the first try, and always before shipping a rule that
someone has an incentive to break (money, ranking, permissions, rate limits). Write the
mutation as the *bug a hurried person would actually introduce* — delete the filter, flip
`>` to `>=`, drop the floor, widen the window — not as random noise.

A surviving mutation is not a style note. It is a rule your suite claims to cover and does not.

### Don't rationalize — the excuse-buster table

| The excuse you're about to make | What it actually requires |
|---|---|
| "It compiles / typechecks, so it works" | Exercise the flow (E3), don't infer runtime from E1 |
| "A subagent / CI said it passed" | Read the actual output, exit code, failure count yourself |
| "It's basically the same as before" | Run it anyway — "basically" is where the bug hides |
| "The happy path works" | Drive the empty / error / unauthorized / concurrent path too |
| "Deploy succeeded (READY)" | Smoke the real endpoint for a marker unique to the NEW build |
| "I'll add the test later" | Later is where regressions ship — pin it now |
| "I wrote the tests and they all passed on the first run" | Passing first try is a **suspicion, not an achievement**: a test that has never been red has never proven it can see. Break the line it is supposed to protect and confirm it screams. Watch especially for assertions on an outcome that SEVERAL causes produce (`state === "blocked"`, `=== null`, `toThrow()`) — the fixture may be landing there for a different reason, and the test covers nothing. The scar: a test named for the anti-fraud filter it was guarding, where deleting that filter entirely left the suite green |
| "It was the infra / the environment / it's just flaky" | Did you observe the AGENT or only the EFFECT? Name the command that would reveal its mark and RUN it (`git reflog` for a reset, `ps`/cron/hooks for a process, `/proc/uptime` for a recycled container, the provider's log for an outage). An absent culprit is never disproven — it becomes folklore. No mark: *"effect observed, cause unknown"* |
| "The page returned 200 / grep found the string" | A 200 can be your error boundary, and a grep for CONTENT matches the error page too. Prove the ABSENCE of failure (error-boundary markup, error digest, 5xx) across N requests — not the presence of a word |
| "The build passed, so the page renders" | Server-side render errors (a non-serializable prop, a function crossing a client boundary) pass typecheck AND build, then fail at RUNTIME — sometimes only on *some* requests. Read the new deployment's runtime log |
| "I only ran a seed / an UPDATE in production, I didn't touch code" | **Direct writes to production have no diff — no guard here can see them.** Bad data breaks rendering without a single line changing. A DATA mutation needs the same proof as a code change: exercise the real flow AFTER the write, and read the runtime log |
| "The production sweep came back clean" | Did it cover the route you actually CHANGED? A static route list never hits a new or dynamic path, and a clean sweep of 35 untouched screens proves nothing about yours |
| "It's merged / it's on main, so it's shipped" | **Merged and released are different events.** A version bump in a manifest is invisible to everyone who is not reading the diff — the tag and the release entry are the shop window. Before saying published, check they EXIST for the new version (`git ls-remote --tags`, the releases page). If cutting the release is someone else's step, the delivery is PENDING that step, not done. Same shape as "the deploy is READY" and "the build finished": a step that feels terminal and is not |
| "The comment says it's safe — I wrote it when I wrote the code" | **A comment asserting a security property is an E3 claim wearing a comment's clothes.** "This can never help an attacker", "callers cannot reach this", "restarting never grants more" — each is a measurable statement about behavior, and a sentence is not a measurement. Either a test drives the attacker's path and compares the outcome, or the sentence is a guess formatted as analysis. Documenting it BACKWARDS is worse than leaving it undocumented: the next reader (often you, hours later) skips the check exactly where it was needed. The scar: a comment promising that re-joining a contest "never grants more credit" sat above code where re-joining moved the start date — cutting the numerator AND the denominator. Two players with identical performance; the one who toggled came out champion |
| "Typecheck / the suite was green" | Green **when**? Evidence has a timestamp. A command that ran before the last file existed says nothing about that file, and the natural order of work — write code, write tests, verify — puts the mid-way run before the thing most likely to be wrong. The mid-way run is a draft, not proof. Re-run it FRESH as the last thing before you claim |
| "The gate passed — every guard came back green" | Green on **which diff**? The base defaults to the merge-base with the default branch, so running the gate AFTER fast-forwarding your work onto it leaves a base that moved *with* the work — the guards then inspect a docs-only diff and each prints its reassuring "nothing touched" line. Read the guard output for lines that CONTRADICT what you just wrote ("mobile app not touched" right after you changed the app), and re-run with `--base <sha before the block>`. The engine warns (`sourceless-diff`), but noticing the contradiction is the real defense |

### Banned language (before the evidence exists)

Don't write **"should", "probably", "seems to", "I think", "Great!", "Perfect!",
"Done!"** — or any paraphrase or implication of success — until step 1's command has
run and you've read its output. If you catch yourself hedging, that's the signal you
haven't verified yet.

Templates: `templates/evidence-report.md` and `templates/root-cause.md` — fill them.

## Step 3 — the adversarial pass, sized to the blast radius

A panel, launched in proportion to what the change can break — cost that does not scale
with risk is cost people learn to skip:

| Class | Who runs |
|---|---|
| **L1** docs/tests/config | nobody |
| **L2** source with callers | `gate-skeptic` |
| **L3** auth · money · migrations · crypto · permissions | `gate-skeptic` + `intent-skeptic` + `security-skeptic` |

`impact.sh --slice` writes what they read: the diff, the first-degree callers of every
changed symbol, the tests that touch them. They read that, not your summary — a summary
is written by the same process that wrote the code and inherits its blind spots.

**The skeptic is held to its own standard.** Every REFUTED must carry a command that
reproduces the problem, and `skeptic.sh record` re-runs it. If it exits 0, or none was
given, the finding is downgraded to UNPROVEN and the downgrade is recorded.

That symmetry is not bureaucracy. A skeptic that writes *"REFUTED: this probably breaks
under load"* has produced an **E0 claim** — words, no run — and because it sounds
rigorous it is trusted more than the claim it just refuted. It is the same failure this
whole skill exists to catch, wearing the other costume, and it costs more: it sends
people to fix what was never broken, and it teaches them to discount the next finding.
A CONFIRMED is capped at the level the ledger recorded, for the mirror-image reason:
agreement is not a run.

What survives is a command that fails today, on this diff. Fix it, or record why the
failure is acceptable. Run `/proofgate:gate` to do the whole ritual at once.

## Step 4 — learn (the self-improvement loop)

If this gate caught something, the lesson becomes DURABLE knowledge NOW — in ~10 lines.
But *where* you write it decides whether it protects anything:

| Level | Form | Depends on someone remembering? |
|---|---|---|
| 1 | in your head / this session | 100% — gone when the session ends |
| 2 | prose in a doc (README, known-issues, CLAUDE.md) | they must read it **and** connect it to the moment |
| 3 | a line in this SKILL (invoked every delivery) | they must invoke and judge |
| **4** | **a guard or test that FAILS LOUD** | **no** |
| **5** | **impossible by construction** | **no** |

**Only 4 and 5 stand on their own. Stopping at level 2 is the anti-pattern** — and it is
not theoretical: the rule about which build a native test flow belonged to was written
in a project's guidelines, in plain words, and the mistake happened anyway, burning 28
minutes of CI. Writing a lesson STORES it; only a guard ENFORCES it. So always ask:

- Can this be a **guard** in `scripts/guards.d/`? (`NN-name.sh`: one grep, `exit 0/1/2`,
  a scar comment, plus a positive AND a negative case in `tests/run-tests.sh` — CI runs
  it automatically.)
- Can it be a **regression test** that pins the exact failure?
- Best of all: can you **derive the value from a single source**, so divergence becomes
  impossible? (A rule copied into five queries drifted and sat inverted for months; the
  fix was deriving all five from one constant — level 5, nothing left to remember.)

Track the ones still stuck at level 2: that list *is* your next tooling backlog — and it
is now literal. A recorded incident opens a **lesson**, and the gate keeps saying so on
every run until something at level 4 answers it:

```sh
memory.sh add --class incident --provenance human --anchor <the file it broke in> \
  --fact "<what actually shipped broken>" [--guard <name that would have caught it>]
```

Close it with a guard (add `proofgate-lesson: <id>` to the guard file), a regression
test, or — when the honest answer is "documented only" — `memory.sh add --resolves <id>`.
A comment in a README does not count: that is level 2 wearing level 4's clothes, and a
test pins the distinction.

### Memory that can go stale, and says so

Facts about the project live in `.proofgate/memory.jsonl` (committed, so it is the
team's, reviewable in a diff). The important part is not that it stores things — it is
that **memory which is wrong is worse than no memory**: a note that was true in March
reads exactly like one that is true today, and the reader, often a model with no way to
check, builds on it.

So every fact is ANCHORED to a file and the blob hash it had when recorded, and
staleness is DERIVED at read time — never stored. Nothing to keep in sync, nothing on the
hot path, and no field an agent can flip to make an inconvenient fact look current.
Decisions hold until revoked; inferences expire when the code they read has moved;
incidents never expire. An *agent's* "decision" expires like the inference it really is —
otherwise a guess becomes permanent policy by choosing a label.

Treat a recall as a hypothesis, not as truth. `[STALE]` means the code moved underneath
it: re-verify before relying on it.

Today's pain is tomorrow's tooling. Re-learning from scratch is forbidden.

## Before you START (pre-flight): define the proof first

At the top of a task, write down the ONE observation that will prove it done (the E3+
evidence). If you can't name it, you don't understand the task yet. Design toward that
observation — not toward "it looks right."

## Seal it, so the reviewer can check instead of believing

```sh
bash scripts/proof.sh seal --push      # or /proofgate:seal
```

Everything above lives in `.git/` and is local. A reviewer reads a description that
*claims* a gate ran and has two options: believe it, or re-do the work — the same
trust-me problem this skill exists to remove, one level up. `seal` attaches the verdict,
the blast radius, the claims for this commit and the skeptic record to the commit as a
git note, hashed, and `--push` sends it with the code.

Be precise about what it proves. It attests to **what the local gate saw**: these
commands ran, with these exit codes and output hashes. It does **not** attest that the
local gate was honest — anything with a shell can write a ledger and seal it. `verify`
catches tampering after the fact; `replay` re-runs the recorded commands and downgrades
the bundle in the note if the evidence no longer reproduces; CI re-running the gate is
the independent check. The note is what makes the two comparable.

## Output template — GENERATED, never typed

```sh
bash scripts/claim.sh render      # or /proofgate:report
```

Paste that output verbatim. It is assembled from the verdict, the blast radius and the
claims ledger, so every line traces to something that ran.

**A status you compose by hand is E0 by construction** — nothing produced it. That is
not a style rule: this whole skill's discipline rested on you volunteering an honest
level at exactly the moment you are most motivated not to, and the render removes the
choice. If it prints `VERIFIED: NOTHING`, that is the delivery's real state, not a
formatting problem.

```
PROOFGATE — <delivery>
Mechanical: ✅ passed · 1 warning(s) · verdict for <sha>
Blast radius: L2 · needs E3 · reachable here: E3 · nav ctags (high)
VERIFIED (level · evidence):
  E3 [central] checkout completes
       ↳ curl -s localhost:3000/health → exit 0 · matched /"build":"<new sha>"/
NOT TESTED (declared):
  · the concurrent path is not exercised
STATUS: central claim at E3 (required E3)
```
