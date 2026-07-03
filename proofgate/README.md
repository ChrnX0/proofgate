<div align="center">

# 🛡️ ProofGate

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

No config. ProofGate auto-detects your stack (pnpm · npm · yarn · bun · Cargo · Go · Python) and judges **the diff you're about to ship**:

```
── ProofGate · mechanical gate ─────────────────────────────
✅ typecheck (pnpm)
✅ tests (pnpm)
✅ working tree clean (everything committed)
✅ HEAD pushed (matches origin/feat/checkout)
✅ secrets: no credential-shaped lines added in the diff
⚠️  PII→logs: 1 added line both logs AND mentions personal-data terms …
⚠️  untested changes: 4 source file(s) changed, 0 test files touched …
✅ env-drift: every env var read in the diff is declared in .env.example
❌ debug-leftovers: 1 focused test(s) added (.only) — the rest of the
   suite is silently OFF. Green CI would be a lie.
────────────────────────────────────────────────────────────
❌ GATE FAILED: 1 item(s). The delivery is NOT done.
```

That `.only` you forgot? It just disabled your entire test suite — and CI was about to go green anyway. **Caught at the gate, not in the postmortem.**

Want it unbypassable? `bash install.sh --hook` → you literally cannot `git push` unproven work.

## 🧠 What ProofGate actually is

A **three-layer delivery gate** that sits between *"the code is written"* and *"the work is done"*:

| Layer | What | Who runs it |
|---|---|---|
| **1 · Mechanical** | tests, push state, secrets, PII-in-logs, untested changes, env drift, coupled files, large files, debug leftovers | a script — `verify.sh` |
| **2 · Judgment** | root cause with evidence · VERIFIED ≠ hoped · production path traced · brutally honest status | you (or your agent), **in writing** |
| **3 · Self-improvement** | every failure becomes a regression test or a new automated guard | the gate itself — it grows |

Born from real production scars: "fixes" that fixed nothing, a documented bug that still reached the user, hopeful patches shipped in the dark. Every rule here has a scar behind it. **This isn't philosophy — it's a rap sheet.**

## 🤖 Give it to your AI agent

ProofGate ships as a **Claude Code plugin**. Two commands:

```
/plugin marketplace add ChrnX0/proofgate
/plugin install proofgate@proofgate
```

Your agent gains the `proofgate` skill: before declaring anything done, it runs the mechanical gate and walks the 9-question judgment gate — delivering an **Evidence Report** instead of a vibe:

```
PROOFGATE — checkout flow fix
Mechanical: ✅ typecheck ✅ tests ✅ pushed ✅ secrets ✅ PII ⚠️ tests-changed (justified below)
VERIFIED: POST /api/orders returns 201 in prod — curl output attached
NOT TESTED: Safari < 16 — no device available; will verify via BrowserStack by Fri
Root cause: race in cart mutex — evidence: Sentry event #4821, repro pinned in test
Lesson recorded: regression test tests/cart-race.test.ts
```

That last section is the culture shift: **"NOT TESTED", written by the agent itself, honestly, before you had to ask.**

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

Or `bash install.sh --ci` scaffolds it for you. Same gate everywhere: agent, laptop, CI.

## 🧩 The judgment gate (layer 2)

The half a script can't do — nine questions, each demanding proof. Full text in [`SKILL.md`](skills/proofgate/SKILL.md); fill-in templates in [`templates/`](templates/).

1. **Root cause with evidence** — and in *which layer* the failure lives. A try/catch in one layer doesn't catch a crash in another.
2. **VERIFIED ≠ hoped** — list what was actually exercised. Empty list = no delivery.
3. **Production path traced** — "deploy succeeded" proves nothing; smoke the real flow.
4. **Cross-check known issues** — rediscovering a documented bug via user complaint is the maximum embarrassment.
5. **Failed twice? Change the approach** — hammering a third time is forbidden.
6. **UI changed? Prove it on the real target** — a dev preview is not the product.
7. **Touched infra? Re-check the obvious** — the trivial detail is the one that humiliates.
8. **Sensitive data on the new path** — pinned by an adversarial test.
9. **Brutally honest status** — VERIFIED / NOT TESTED / PARTIAL. An inflated status is worse than a bug.

## 🔌 Guards are plugins — and this repo eats its own dog food

Every automated check is a ~20-line script in [`guards.d/`](skills/proofgate/scripts/guards.d/). Exit `0` pass · `1` fail · `2` warn. That's the whole API.

| Guard | Catches | Severity |
|---|---|---|
| `10-secrets` | API keys, tokens, private keys entering the diff | ❌ FAIL |
| `20-pii-logging` | personal data flowing into logs/telemetry | ⚠️ |
| `30-untested-changes` | source changed, zero test files touched | ⚠️ |
| `40-env-drift` | `process.env.X` added but missing from `.env.example` | ⚠️ |
| `50-coupled-files` | file pairs that must move together, drifting apart | ⚠️ |
| `60-large-files` | 3MB "quick test video" entering git history forever | ⚠️ |
| `70-debug-leftovers` | `.only` focused tests (suite silently OFF) | ❌ FAIL |

**Every guard is proven on both paths** — fires on the sin, stays quiet on a clean diff — by [`tests/run-tests.sh`](tests/run-tests.sh), on every push, in [this repo's own CI](https://github.com/ChrnX0/proofgate/actions). The acceptance gate has its own acceptance tests.

When production burns you in a way a script could have caught: copy [`TEMPLATE.sh.example`](skills/proofgate/scripts/guards.d/TEMPLATE.sh.example), drop a file, done. **Today's pain becomes tomorrow's tooling — permanently.**

## ⚙️ Configuration (optional)

`proofgate.json` at your repo root — see [`examples/`](examples/proofgate.json):

```json
{
  "commands": { "test": "pnpm test", "typecheck": "pnpm typecheck" },
  "coupledFiles": [
    { "a": "src/lib/db.ts", "b": "db/schema.sql", "reason": "dev schema ↔ prod mirror" }
  ],
  "piiTerms": "password|ssn|cpf|credit.?card|phone|medical",
  "envExample": ".env.example"
}
```

Flags: `--build` · `--strict` (warnings become failures) · `--dry-run` · `--base <ref>` · `--report <file>`.

## ❓ FAQ

**Isn't this just a linter?**
No. Linters judge *how code is written*. ProofGate judges *whether the delivery is proven* — tests ran, secrets absent, claims backed by evidence, honest status written. Layer 2 checks things no static tool can see.

**I already have CI. Why this?**
CI tells you tests passed. ProofGate demands the part CI can't: *what was exercised for real, what wasn't, and where the evidence lives.* Also: it runs **before** the push, when fixing is cheap. (And it runs *in* CI too.)

**Will it slow me down?**
The mechanical gate is your test suite + milliseconds of diff greps. The judgment gate is five minutes of writing you were going to owe anyway — with interest — after the incident.

**I don't use AI agents. Still useful?**
Yes — humans invented "done, I think" long before LLMs industrialized it. The hook + CI modes are agent-free.

**False positives?**
The guard design rule is *low false-positive above all* (see [CONTRIBUTING](CONTRIBUTING.md)). Warnings demand a one-line justification, not silence — and `--strict` is opt-in.

## 🗺️ Roadmap

- Per-workspace monorepo awareness (changed packages only)
- Entropy-based secret detection
- Pre-commit flavor + more stack auto-detections
- Gate-result history: is your team's evidence discipline trending up?

**Contributing:** the best PR is a [new guard with a scar behind it](CONTRIBUTING.md). Tell us what shipped broken the day it became a rule.

## 📜 License

[MIT](LICENSE) — take it, ship it, **prove it**.

---

<div align="center">

**ProofGate** — *one gate, three layers, zero excuses.*

*If it saved you one 2 a.m. rollback, star the repo so it can save someone else's.* ⭐

</div>
