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

No config. ProofGate auto-detects your stack (pnpm · npm · yarn · bun · Cargo · Go · Python · Gradle/Maven · .NET · Ruby · PHP · Elixir · Deno) and judges **the diff you're about to ship** with 17 guards:

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

A **four-layer delivery gate** that sits between *"the code is written"* and *"the work is done"*:

| Layer | What | Who runs it |
|---|---|---|
| **1 · Mechanical** | tests · lint · push state · **17 diff guards** (secrets, PII-in-logs, TLS-off, merge markers, silenced tests/types, money-as-float, hand-built SQL, …) → a **SHA-bound verdict** | a script — `verify.sh` |
| **2 · Judgment** | root cause + counter-proof · an **evidence hierarchy** (believed → static → tested → exercised → in-prod; "done" needs ≥ exercised) · brutally honest status | you (or your agent), **in writing** |
| **3 · Adversarial** | a **default-refute skeptic** tries to break every "it works" claim against the diff | the `gate-skeptic` subagent |
| **4 · Enforcement** | hooks refuse to `git push` — or (opt-in) to declare *done* — without a fresh passing verdict | `push-guard` / `stop-guard` |

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

Your agent gains:
- the **`proofgate` skill** — runs the mechanical gate and walks the judgment gate before declaring anything done;
- **`/proofgate:gate`** — the full ritual on demand;
- the **`gate-skeptic`** subagent — an adversarial pass over its own claims;
- the **push-guard** hook — no push without a fresh passing verdict (and `stopGuard:true` extends that to "no *done* without one").

The payoff is an **Evidence Report** instead of a vibe — with the evidence *level* stated:

```
PROOFGATE — checkout flow fix
Mechanical: ✅ typecheck ✅ lint ✅ tests ✅ committed ✅ guards (17)
VERIFIED (E4): POST /api/orders returns 201 in prod — curl output attached
NOT TESTED: Safari < 16 — no device; will verify via BrowserStack by Fri
Root cause: race in cart mutex — Sentry #4821, repro pinned; counter-proof checked
Lesson recorded: regression test tests/cart-race.test.ts
```

That `VERIFIED (E4)` and that honest `NOT TESTED`, **written by the agent itself before you had to ask** — that's the culture shift.

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

It writes `::error`/`::warning` annotations, a step-summary table, and outputs (`fails`, `warns`, `verdict-path`). Or `bash install.sh --ci` scaffolds it. Same gate everywhere: agent, laptop, CI.

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

**Every guard is proven on both paths** — fires on the sin, stays quiet on a clean diff — by [`tests/run-tests.sh`](tests/run-tests.sh) (**61 cases**, engine + hooks included), on every push, on Linux **and** macOS, in [this repo's own CI](https://github.com/ChrnX0/proofgate/actions). The acceptance gate has its own acceptance tests.

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
  "skip": ["sql-concat"],
  "severity": { "pii-logging": "fail" },
  "guardsDirs": [".proofgate-guards"],
  "smoke": [{ "name": "health", "url": "https://app.example.com/health", "status": 200, "expect": "ok" }],
  "pushGuard": true,
  "stopGuard": false
}
```

Config reads with jq, node, **or** python3 — whichever exists (zero hard dependency). Flags: `--build` · `--strict` · `--smoke` · `--json` · `--only <guard>` · `--dry-run` · `--base <ref>` · `--report <file>`.

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

- Per-workspace monorepo awareness (changed packages only)
- Entropy-based secret detection
- SARIF / rdjson export for code-scanning ingestion
- Cross-model skeptic (a second model as independent auditor)
- Gate-result history: is your team's evidence discipline trending up? (the `.git/proofgate-ledger.jsonl` groundwork is in place)

**Contributing:** the best PR is a [new guard with a scar behind it](CONTRIBUTING.md). Tell us what shipped broken the day it became a rule.

## 📜 License

[MIT](LICENSE) — take it, ship it, **prove it**.

---

<div align="center">

**ProofGate** — *four layers, one verdict, zero excuses.*

*If it saved you one 2 a.m. rollback, star the repo so it can save someone else's.* ⭐

</div>
