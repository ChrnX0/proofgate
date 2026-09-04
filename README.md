<div align="center">

# 🛡️ Anti-Stupidity xD

### The acceptance gate that doesn't accept *"I think it works."*

[![CI](https://github.com/ChrnX0/proofgate/actions/workflows/ci.yml/badge.svg)](https://github.com/ChrnX0/proofgate/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757.svg)](#-give-it-to-your-ai-agent)
[![GitHub Action](https://img.shields.io/badge/GitHub%20Action-ready-2ea44f.svg)](#%EF%B8%8F-run-it-in-ci)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

**Compiled ≠ works. Deployed ≠ verified. Plausible ≠ proven.**

</div>

---

Your AI agent just said **"Done! ✨"**

It compiled? Sure. It works? *Nobody checked.* Three days later the bug surfaces — in production, in front of a user, and **you** are the one who finds it.

Every developer working with AI agents knows this movie. **ProofGate cancels the premiere.**

> **Golden rule: a checklist without evidence is theater.**
> Every claim gets answered with a command that ran, a link, or a number — never with *"I believe so."*

## ⚡ 60 seconds to your first gate

```sh
curl -fsSL https://raw.githubusercontent.com/ChrnX0/proofgate/main/install.sh | bash
bash .proofgate/verify.sh
```

No config. ProofGate auto-detects your stack (pnpm · npm · yarn · bun · Cargo · Go · Python · Gradle/Maven · .NET · Ruby · PHP · Elixir · Deno) and judges **the diff you're about to ship** with 24 guards:

```
── ProofGate · mechanical gate ─────────────────────────────
✅ typecheck (pnpm)
✅ tests (pnpm)
✅ working tree clean (everything committed)
✅ secrets: no credential-shaped lines added in the diff
⚠️  PII→logs: 1 added line both logs AND mentions personal-data terms …
⚠️  untested changes: 4 source file(s) changed, 0 test files touched …
❌ tls-off: 1 added line DISABLES TLS/cert verification in code …
❌ debug-leftovers: 1 focused test(s) added (.only) — the rest of the
   suite is silently OFF. Green CI would be a lie.
────────────────────────────────────────────────────────────
❌ GATE FAILED: 2 item(s). The delivery is NOT done.
```

That `.only` you forgot? It just disabled your entire test suite — and CI was about to go green anyway. **Caught at the gate, not in the postmortem.** Every full run also writes a machine-readable, **SHA-bound verdict** to `.git/proofgate-verdict.json`.

Want it unbypassable? `bash install.sh --hook` → you literally cannot `git push` unproven work.

## 🧠 What ProofGate actually is

A **delivery gate** that sits between *"the code is written"* and *"the work is done"* — and that charges in proportion to what the change can break:

| Layer | What | Who runs it |
|---|---|---|
| **0 · Blast radius** | what this diff can break — changed symbols, their callers, affected tests — over the **whole branch + your working tree**, classified **L1/L2/L3**. That class sets the price of the gate: docs pay E1, source pays E3, auth/money/migrations also pay a mandatory skeptic | a script — `impact.sh` |
| **1 · Mechanical** | tests · lint · push state · **24 diff guards** (secrets, PII-in-logs, TLS-off, merge markers, silenced tests/types, money-as-float, hand-built SQL, un-migrated schema constraints, version-bumped-but-never-released, …) → a **SHA-bound verdict** | a script — `verify.sh` |
| **2 · Judgment** | root cause + counter-proof · an **evidence hierarchy** (believed → static → tested → exercised → in-prod; "done" needs ≥ exercised) · **diagnosis as a falsifiable hypothesis that survives a context compaction** · a status **generated from the ledger, never typed** | `claim.sh` · `hypothesis.sh` · `memory.sh` |
| **3 · Adversarial** | a **default-refute panel**, sized to the radius, tries to break every "it works" claim — and every refutation is itself re-run, so a skeptic cannot assert a break either | `gate-skeptic` · `intent-skeptic` · `security-skeptic` |
| **4 · Enforcement** | hooks refuse to `git push` — or (opt-in) to declare *done* — without a fresh passing verdict, and (opt-in) to edit source while a bugfix has no failing test | `push-guard` · `stop-guard` · `edit-guard` |
| **5 · Proof** | the verdict, radius, claims and skeptic record **sealed to the commit** as a git note that travels with the push and CI verifies | `proof.sh seal` |

Born from real production scars: "fixes" that fixed nothing, a documented bug that still reached the user, hopeful patches shipped in the dark. Every rule here has a scar behind it. **This isn't philosophy — it's a rap sheet.**

## 🚫 Why your agent can't just bypass it

The uncomfortable truth of agentic coding: *the thing you're gating is also the thing trying to get past the gate.* Agents have been caught skipping `pre-commit` hooks with `git push --no-verify`, `git stash`, and quiet flags — [it's a documented failure mode](https://github.com/anthropics/claude-code/issues/40117).

ProofGate's push-guard is a **PreToolUse hook**: it sees the raw command *before* git does. `git push --no-verify` skips a git pre-push hook — it does **not** skip this one, and the attempt itself is flagged. The verdict is bound to the commit SHA, so editing files after a green run invalidates it. The escape hatch is explicit and honest (`pushGuard:false`, `PROOFGATE_HOOK_OFF=1`) — not a flag the agent can quietly reach for.

## 🤖 Give it to your AI agent

ProofGate ships as a **Claude Code plugin**. Two commands:

```
/plugin marketplace add ChrnX0/proofgate
/plugin install proofgate@proofgate
```

Your agent gains a **protocol**, not just a checkpoint —
RECALL → HYPOTHESIZE → EXPERIMENT → IMPLEMENT → PROVE → SEAL → REPORT, each phase
anchored by a command or a hook rather than a reminder:

| | |
|---|---|
| **`proofgate` skill** | the protocol itself; invoked before anything is called done |
| **`/proofgate:preflight`** | measure the radius, recall what the project knows, name the E3 observation, open a falsifiable hypothesis — all things that are impossible or dishonest to do afterwards |
| **`/proofgate:claim`** | record a claim by RUNNING the command that proves it |
| **`/proofgate:experiment`** | test an idea in its own worktree, several at once, leaving nothing behind |
| **`/proofgate:gate`** | the full ritual: radius → mechanical → skeptic panel → seal → render |
| **`/proofgate:report`** | the status block, generated from the ledger |
| **`/proofgate:seal`** | attach the evidence to the commit as a git note |
| **`/proofgate:prototype`** · **`/proofgate:calibration`** | explore loudly; see which guards earn their noise |
| **3 skeptic subagents** | correctness, scope, and security — launched in proportion to the risk class |
| **7 hooks** | refuse an unproven push; refuse "done"; refuse a fix with no failing test; re-inject what a compaction dropped; report a guard finding at the moment of the edit; announce prototype mode every turn; keep a command chronology |

The payoff is an **Evidence Report** instead of a vibe — and the important part is that
**the agent does not write it**. It is rendered from rows that each name a command that
ran, its exit code and a hash of its output:

```sh
/proofgate:report
```

```
PROOFGATE — checkout flow fix
Mechanical: ✅ passed · 1 warning(s) · verdict for a1b2c3d
Blast radius: L3 · needs E3 · reachable here: E4 · nav ctags (high)
VERIFIED (level · evidence):
  E2 [red-test]   the bug reproduces: this command is RED before the fix
       ↳ npx vitest run src/cart.test.ts → exit 1
  E2 [green-test] the same command that was red now passes
       ↳ npx vitest run src/cart.test.ts → exit 0
  E4 [central]    checkout completes against production
       ↳ curl -s https://app.example.com/version → exit 0 · matched /"build":"a1b2c3d"/
NOT TESTED (declared):
  · Safari < 16 — no device; BrowserStack run scheduled Friday
STATUS: central claim at E4 (required E3)
```

That `E4` was not typed. `claim.sh` ran `curl`, read the exit code, and checked for a
marker **unique to the new build** — because a `200` is perfectly compatible with the old
one still being live. **A status composed by hand is E0 by construction**: nothing
produced it. That is the culture shift, and it is now a mechanism rather than a habit.

## 🏗️ Run it in CI

```yaml
# .github/workflows/proofgate.yml
name: proofgate
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ChrnX0/proofgate@main
        with:
          strict: "false"   # start soft; flip to "true" when the team is ready
```

It writes `::error`/`::warning` annotations, a step-summary table, and outputs (`fails`, `warns`, `verdict-path`, `proof`). Or `bash install.sh --ci` scaffolds it. Same gate everywhere: agent, laptop, CI.

The job also **verifies the sealed proof note** on the branch head and renders it into the
step summary. A *missing* note does not fail the build — a team adopting this has commits
from before they started sealing, and failing those teaches everyone the check is noise.
A **tampered** one does, because that is a positive signal rather than an absence. Set
`require-proof-note: "true"` when every commit is expected to carry one.

## 🧩 The judgment gate (layer 2)

The half a script can't do. Its spine is the **evidence hierarchy** — where does your central claim actually sit?

| Level | Name | Proves |
|---|---|---|
| E0 | believed | nothing — it's just words |
| E1 | static | it typechecks/lints. Not that it works. |
| E2 | automated test | a test exercises the change and passes |
| E3 | exercised end-to-end | the real flow was DRIVEN on the real runtime and observed |
| E4 | in production | the deployed system was seen doing it |

**A runtime claim ("fixed", "works") is DONE only at E3+.** On top of that: root cause *and counter-proof*, production path with a marker unique to the NEW build, cross-checked known issues, failed-twice-→-change-approach, honest VERIFIED/NOT-TESTED/PARTIAL status — plus a banned-hedging-language list and an excuse-buster table. Full text in [`SKILL.md`](skills/proofgate/SKILL.md); fill-in templates in [`templates/`](templates/).

## 🧬 `mutate` — the only proof that a test can *see*

A green suite proves the code passes the tests. It does **not** prove the tests would catch the code being wrong. The only proof of that is to break the code on purpose and check the suite screams.

```sh
node skills/proofgate/scripts/mutate.mjs src/pricing.ts -- npx vitest run src/pricing.test.ts <<'EOF'
{"name": "discount floor removed", "from": "Math.max(0, total)", "to": "total"}
{"name": "expiry check inverted",   "from": "now < expiresAt",    "to": "now > expiresAt"}
EOF
```

Language-agnostic — it only needs a file to edit and a command to run (`pytest`, `go test`, `cargo test`, anything). It requires a **green baseline**, requires each `from` to occur **exactly once**, restores the file on every exit path, and reports survivors with **exit 1**. Empty input is **exit 2**: a run that mutated nothing must never look like a run where nothing survived.

**A surviving mutation is not a style note — it is a rule your suite claims to cover and does not.** On the delivery that motivated this tool, 47 mutations found 6 blind tests.

## 🔌 Guards are plugins — and this repo eats its own dog food

Every automated check is a small script in [`guards.d/`](skills/proofgate/scripts/guards.d/). Exit `0` pass · `1` fail · `2` warn. That's the whole API.

| Guard | Catches | Severity |
|---|---|---|
| `10-secrets` | API keys, tokens, private keys (+ generic assignments) | ❌ / ⚠️ |
| `12-merge-markers` | unresolved `<<<<<<<` conflict markers | ❌ FAIL |
| `15-tls-off` | `rejectUnauthorized:false`, `verify=False`, `curl -k` | ❌ / ⚠️ |
| `20-pii-logging` | personal data flowing into logs/telemetry | ⚠️ |
| `25-silent-catch` | `catch{}` / `except: pass` / `rescue nil` | ⚠️ |
| `30-untested-changes` | source changed, zero test files touched | ⚠️ |
| `35-dependency-change` | manifest changed without its lockfile | ⚠️ |
| `40-env-drift` | env var read but missing from `.env.example` | ⚠️ |
| `50-coupled-files` | file pairs that must move together, drifting | ⚠️ |
| `55-skipped-tests` | `.skip` / `xit` / `@pytest.mark.skip` added | ⚠️ |
| `58-frozen-clock` | a test reading the real wall clock (time bomb) | ⚠️ |
| `60-large-files` | a 3MB blob entering git history forever | ⚠️ |
| `65-type-suppressions` | `@ts-ignore` / `# type: ignore` / `noqa` / `nosec` | ⚠️ |
| `70-debug-leftovers` | `.only` focused tests · `debugger` · fresh TODOs | ❌ / ⚠️ |
| `75-machine-paths` | `/home/<you>` / `C:\Users\…` hard-coded | ⚠️ |
| `85-float-money` | money through a float (`parseFloat`, `.toFixed`) | ⚠️ |
| `90-sql-concat` | SQL built by string concatenation | ⚠️ |
| `93-hypothesis-required` | a fix branch with no recorded hypothesis — a cause never written down is never falsified | ⚠️ |
| `95-schema-constraint-no-migration` | a constraint added to a table with no migration for it | ⚠️ |
| `96-version-bump-no-release` | the version moved and no release was ever cut | ⚠️ |
| `97-memory-stale` | a recorded fact is anchored to a file in this diff, and the anchor no longer matches | ⚠️ |
| `98-unlearned-lessons` | an incident with nothing enforcing its lesson yet | ⚠️ |
| `99-skeptic-required` | an L3 change with no adversarial pass — or one whose refutations still reproduce | ⚠️ / ❌ |

**Every guard is proven on both paths** — fires on the sin, stays quiet on a clean diff — by [`tests/run-tests.sh`](tests/run-tests.sh) (**246 cases**, engine, hooks, ledgers and scripts included), on every push, on Linux **and** macOS, in [this repo's own CI](https://github.com/ChrnX0/proofgate/actions).

On top of that, [`tests/acceptance.sh`](tests/acceptance.sh) drives **the whole protocol end to end in a real repository with a real remote** — 18 steps, from measuring the radius to detecting a tampered proof note. That distinction is not ceremony: it caught three defects the unit suite could not see — including one introduced by a fix that every unit test approved. Every piece obeying its spec is not the same as the path through them working — which is, more or less, this entire project's thesis applied to itself.

False positive? Three escape hatches: a `proofgate-allow` comment on the line, a `guard:file:hash` fingerprint in `.proofgateignore`, or `skip`/`severity` in `proofgate.json`. When production burns you in a way a script could have caught: copy [`TEMPLATE.sh.example`](skills/proofgate/scripts/guards.d/TEMPLATE.sh.example), drop a file, done. **Today's pain becomes tomorrow's tooling — permanently.**

## ⚙️ Configuration (optional)

`proofgate.json` at your repo root — full reference in [`examples/`](examples/proofgate.json):

```json
{
  "commands": { "test": "pnpm test", "typecheck": "pnpm typecheck", "lint": "pnpm lint" },
  "coupledFiles": [
    { "a": "src/lib/db.ts", "b": "db/schema.sql", "reason": "dev schema ↔ prod mirror" }
  ],
  "piiTerms": "password|ssn|cpf|credit.?card|phone|medical",
  "sensitiveGlobs": "(^|/)(auth|billing|payment|migration)s?(/|[._-])",
  "impact": { "backendCmd": "", "maxSymbols": 100, "maxCallers": 500 },
  "skip": ["sql-concat"],
  "severity": { "pii-logging": "fail" },
  "guardsDirs": [".proofgate-guards"],
  "smoke": [{ "name": "health", "url": "https://app.example.com/health", "status": 200, "expect": "ok" }],

  "pushGuard": true,
  "stopGuard": false,
  "editGuard": false,
  "liveGuards": false,
  "audit": false,
  "requireProof": false,
  "requireSkeptic": false,
  "memory": { "ttlDiffs": 20, "agentDecisionsExpire": true },
  "hypothesis": { "branchPattern": "(^|/)(fix|bugfix|hotfix|patch)", "strikeThreshold": 2 },
  "experiment": { "link": ["node_modules", ".venv", "target"], "timeoutSeconds": 900 }
}
```

**Everything added after 2.6 is opt-in and off by default** — `editGuard`, `liveGuards`,
`audit`, `requireProof`, `requireSkeptic`. That is deliberate: the intrusive rules are the
ones a team must choose, because a rule imposed on a team that has not chosen it is a rule
they route around, and the routing-around generalises to the rules that mattered.

Config reads with jq, node, **or** python3 — whichever exists (zero hard dependency). Flags: `--build` · `--strict` · `--smoke` · `--json` · `--only <guard>` · `--dry-run` · `--base <ref>` · `--report <file>` · `--no-impact`. `--only` searches the engine's guards **and** your `guardsDirs`, so you can iterate on a guard you just wrote without paying for a full run.

`--base` defaults to the merge-base with your default branch. If you run the gate **after** merging the work into that branch, the base moves with it and the guards end up inspecting a docs-only diff — reporting "nothing touched" for changes you just shipped. ProofGate warns about that (`sourceless-diff`); pass `--base <sha before the work>` to re-run against the real range.

### 🎯 Why the gate does not cost the same for every change

A gate with one fixed price is a gate people switch off. So `impact.sh` measures the
change before judging it, and the measurement decides the price:

| Class | What it is | Owes |
|---|---|---|
| **L1** | docs, tests, config only | E1 (static) |
| **L2** | source with callers | **E3** — the real flow, driven |
| **L3** | auth · money · migrations · crypto · permissions | **E3 + a mandatory adversarial pass** |

Two things make that hard to game. The radius is computed over the **whole branch plus
your uncommitted work**, so hiding a migration in an earlier commit and gating the docs
commit on top does not lower the class. And "sensitive" is decided by **content as well
as path** — money math filed under `utils/helpers.ts` is still L3.

It is also honest about its own eyesight. With Universal Ctags on PATH it reads a real
symbol table (`navigation_confidence: high`); without it, callers come from a
word-boundary grep and it says `low` — plus a `degradations` list naming what it could
not do. An empty caller list from a low-confidence run means *"I did not find any"*, not
*"there are none"*, and the output never lets you confuse the two. Point `impact.backendCmd`
at a real language server and it hands the job over.

### 📎 The evidence travels with the commit

Everything above lives in `.git/` and is local. The reviewer of your pull request reads a
description that *claims* a gate ran, and has two options: believe it, or re-do the work
— which is the same trust-me problem, one level up.

```sh
bash .proofgate/proof.sh seal --push     # → refs/notes/proofgate on this commit
```

The note carries the verdict, the blast radius, the claims for this commit, the skeptic
record and the audit segment those claims rest on, each hashed. It does not change the
commit, it travels with a push, and the GitHub Action verifies it into the job summary.

**Be precise about what that proves.** It attests to *what the local gate saw*: these
commands ran, with these exit codes and output hashes. It does **not** attest that the
local gate was honest — anything with a shell can write a ledger and seal it. So:

- `proof.sh verify` catches tampering **after** sealing (the hashes stop matching);
- `proof.sh replay` re-runs the recorded commands and **downgrades the bundle in place**
  if the evidence no longer reproduces;
- CI re-running the gate is the independent check. The note is what makes the two
  comparable, and what turns "trust me" into something a reviewer can check in a second.

The same honesty applies to the enforcement layer generally: hash-chained ledgers make a
hand-written row **evident**, not impossible; the edit-guard can be walked around by
editing through Bash. Every one of those limits is stated in the code that implements it.
This raises the cost of a false claim and makes the expensive version visible — it does
not make lying impossible, and a tool that claimed otherwise would be doing exactly what
it exists to prevent.

## ❓ FAQ

**Isn't this just a linter?**
No. Linters judge *how code is written*. ProofGate judges *whether the delivery is proven* — tests ran, secrets absent, claims backed by evidence at the right level, honest status written. Layers 2–4 check things no static tool can see.

**I already have CI. Why this?**
CI tells you tests passed. ProofGate demands the part CI can't: *what was exercised for real, at what level, what wasn't, and where the evidence lives.* Also: it runs **before** the push, when fixing is cheap. (And it runs *in* CI too.)

**Will it slow me down?**
The mechanical gate is your test suite + milliseconds of diff greps. The judgment gate is five minutes of writing you were going to owe anyway — with interest — after the incident.

**I don't use AI agents. Still useful?**
Yes — humans invented "done, I think" long before LLMs industrialized it. The hook + CI modes are agent-free.

**False positives?**
The guard design rule is *low false-positive above all* (see [CONTRIBUTING](CONTRIBUTING.md)). Warnings demand a one-line justification, not silence; `--strict` is opt-in; and every guard has three suppression escape hatches.

## 🗺️ Roadmap

- A reference `impact.backendCmd` implementation — real LSP go-to-definition instead of ctags/grep, so `navigation_confidence` can be `high` on every stack rather than the ones ctags parses
- Per-workspace monorepo awareness (changed packages only)
- Cross-repo memory: an incident recorded in one service warning the next one that touches the same shape
- Entropy-based secret detection
- SARIF / rdjson export for code-scanning ingestion
- **Cross-model skeptic** — the panel is adversarial but shares one model's blind spots; a second model as independent auditor is the honest next step
- Gate-result history: is your team's evidence discipline trending up? (`verify.sh --calibration` is the first slice of this; the ledgers hold the rest)

**Contributing:** the best PR is a [new guard with a scar behind it](CONTRIBUTING.md). Tell us what shipped broken the day it became a rule.

## 📜 License

[MIT](LICENSE) — take it, ship it, **prove it**.

---

<div align="center">

**ProofGate** — *six layers, one verdict, zero excuses.*

*If it saved you one 2 a.m. rollback, star the repo so it can save someone else's.* ⭐

</div>
