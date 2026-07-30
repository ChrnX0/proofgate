---
name: proofgate
description: Acceptance gate to run BEFORE declaring any delivery "done" (feature, bugfix, release, deploy, PR merge-ready). Four layers — a mechanical gate (tests, push state, 18 diff guards) that writes a SHA-bound verdict, a judgment gate with an evidence hierarchy (believed → static → tested → exercised → in-prod) that demands proof for every claim, an adversarial skeptic pass, and hooks that refuse to push or declare done without a fresh passing verdict. Also use when a bug reappears or a fix has failed twice.
---

# ProofGate — acceptance with EVIDENCE, not hope

This gate exists because of a pattern every developer working with AI agents knows:
**"Done!" — and then the blank screen.** Compiled ≠ works. Deployed ≠ verified.
Plausible ≠ proven.

**Golden rule: a checklist without evidence is theater.** Every item below is
answered with a COMMAND THAT RAN, a LINK, a NUMBER — never with "I believe so."

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

Auto-detects your stack (pnpm/npm/yarn/bun, Cargo, Go, Python, Gradle/Maven, .NET,
Ruby, PHP, Elixir, Deno) and runs what the machine checks better than judgment:
typecheck / lint / tests (/ build) actually green; working tree committed; **18
diff guards** (secrets, PII-in-logs, TLS-off, merge markers, silenced tests/types,
money-as-float, hand-built SQL, machine paths, dependency-lockfile drift,
un-migrated schema constraints, …).
Every full run writes a **SHA-bound verdict** to `.git/proofgate-verdict.json`.

**Any ❌ = the delivery is NOT done.** Every ⚠️ demands a written justification —
never silent dismissal. False positive? `proofgate-allow` on the line, a
`.proofgateignore` fingerprint, or `skip`/`severity` in `proofgate.json`.

## Step 2 — the JUDGMENT gate (one by one, with proof)

### The evidence hierarchy — where does your central claim actually sit?

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

1. **Hypothesis** — the mechanism, in one sentence. *"A process runs `git reset` on the repo."*
2. **Falsifiable prediction** — if that were true, what MUST exist? *"A `reset` in the
   reflog; a process in `ps`; an entry in a log, cron or hook."*
3. **Command** — the one that reveals that mark. Run it.
4. **Read** — is the mark there? If NOT, the hypothesis is dead. Don't patch it. Replace it.

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

### Don't rationalize — the excuse-buster table

| The excuse you're about to make | What it actually requires |
|---|---|
| "It compiles / typechecks, so it works" | Exercise the flow (E3), don't infer runtime from E1 |
| "A subagent / CI said it passed" | Read the actual output, exit code, failure count yourself |
| "It's basically the same as before" | Run it anyway — "basically" is where the bug hides |
| "The happy path works" | Drive the empty / error / unauthorized / concurrent path too |
| "Deploy succeeded (READY)" | Smoke the real endpoint for a marker unique to the NEW build |
| "I'll add the test later" | Later is where regressions ship — pin it now |
| "It was the infra / the environment / it's just flaky" | Did you observe the AGENT or only the EFFECT? Name the command that would reveal its mark and RUN it (`git reflog` for a reset, `ps`/cron/hooks for a process, `/proc/uptime` for a recycled container, the provider's log for an outage). An absent culprit is never disproven — it becomes folklore. No mark: *"effect observed, cause unknown"* |
| "The page returned 200 / grep found the string" | A 200 can be your error boundary, and a grep for CONTENT matches the error page too. Prove the ABSENCE of failure (error-boundary markup, error digest, 5xx) across N requests — not the presence of a word |
| "The build passed, so the page renders" | Server-side render errors (a non-serializable prop, a function crossing a client boundary) pass typecheck AND build, then fail at RUNTIME — sometimes only on *some* requests. Read the new deployment's runtime log |
| "I only ran a seed / an UPDATE in production, I didn't touch code" | **Direct writes to production have no diff — no guard here can see them.** Bad data breaks rendering without a single line changing. A DATA mutation needs the same proof as a code change: exercise the real flow AFTER the write, and read the runtime log |
| "The production sweep came back clean" | Did it cover the route you actually CHANGED? A static route list never hits a new or dynamic path, and a clean sweep of 35 untouched screens proves nothing about yours |
| "It's merged / it's on main, so it's shipped" | **Merged and released are different events.** A version bump in a manifest is invisible to everyone who is not reading the diff — the tag and the release entry are the shop window. Before saying published, check they EXIST for the new version (`git ls-remote --tags`, the releases page). If cutting the release is someone else's step, the delivery is PENDING that step, not done. Same shape as "the deploy is READY" and "the build finished": a step that feels terminal and is not |
| "The gate passed — every guard came back green" | Green on **which diff**? The base defaults to the merge-base with the default branch, so running the gate AFTER fast-forwarding your work onto it leaves a base that moved *with* the work — the guards then inspect a docs-only diff and each prints its reassuring "nothing touched" line. Read the guard output for lines that CONTRADICT what you just wrote ("mobile app not touched" right after you changed the app), and re-run with `--base <sha before the block>`. The engine warns (`sourceless-diff`), but noticing the contradiction is the real defense |

### Banned language (before the evidence exists)

Don't write **"should", "probably", "seems to", "I think", "Great!", "Perfect!",
"Done!"** — or any paraphrase or implication of success — until step 1's command has
run and you've read its output. If you catch yourself hedging, that's the signal you
haven't verified yet.

Templates: `templates/evidence-report.md` and `templates/root-cause.md` — fill them.

## Step 3 — the adversarial pass (recommended)

Launch the **gate-skeptic** subagent (default-refute) to try to break your claims
against the diff. Resolve or honestly downgrade every REFUTED/UNPROVEN before
declaring done. Or run `/proofgate:gate` to do the whole ritual at once.

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

Track the ones still stuck at level 2: that list *is* your next tooling backlog.

Today's pain is tomorrow's tooling. Re-learning from scratch is forbidden.

## Before you START (pre-flight): define the proof first

At the top of a task, write down the ONE observation that will prove it done (the E3+
evidence). If you can't name it, you don't understand the task yet. Design toward that
observation — not toward "it looks right."

## Output template (paste into your status/PR)

```
PROOFGATE — <delivery>
Mechanical: ✅ typecheck ✅ lint ✅ tests ✅ build ✅ committed ✅ guards (18)
VERIFIED (level): <central claim @ E3 — flow X driven via curl/e2e/screenshot + evidence>
NOT TESTED: <what + how it will be>
Root cause (if fix): <layer + evidence + counter-proof checked>
Lesson recorded: <guard/test/doc> | none
```
