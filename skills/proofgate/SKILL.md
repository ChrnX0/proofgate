---
name: proofgate
description: Acceptance gate to run BEFORE declaring any delivery "done" (feature, bugfix, release, deploy, PR merge-ready). Three layers — a mechanical gate (tests, push state, secrets, PII-in-logs, untested changes, coupled files), a judgment gate that demands EVIDENCE for every claim (root cause, verified vs. hoped, production path, honest status), and a self-improvement step that turns every failure into a permanent guard. Also use when a bug reappears or a fix has failed twice.
---

# ProofGate — acceptance with EVIDENCE, not hope

This gate exists because of a pattern every developer working with AI agents knows:
**"Done!" — and then the blank screen.** Compiled ≠ works. Deployed ≠ verified.
Plausible ≠ proven.

**Golden rule: a checklist without evidence is theater.** Every item below is
answered with a COMMAND THAT RAN, a LINK, a NUMBER — never with "I believe so."

## Step 1 — the MECHANICAL gate (automated)

```sh
bash "$(dirname "$0")/scripts/verify.sh"            # from the skill dir, or:
bash scripts/verify.sh                              # if vendored into your repo
bash scripts/verify.sh --build                      # include the build (pre-release)
bash scripts/verify.sh --strict                     # warnings become failures
bash scripts/verify.sh --dry-run                    # show what would run
bash scripts/verify.sh --report proofgate-report.md # write a markdown artifact
```

The script auto-detects your stack (pnpm/npm/yarn/bun, Cargo, Go, Python) and runs
what the machine checks better than judgment:

- typecheck / tests (/ build with `--build`) actually green — not "should pass"
- working tree committed AND pushed — unpushed work is work that can vanish
- **secrets added in the diff** (API keys, tokens, private keys) → hard FAIL
- **PII flowing into logs** in added lines (configurable term list) → warn/FAIL
- source changed with **zero test changes** → warn
- **env-var drift**: new `process.env.X` not declared in `.env.example` → warn
- **coupled files**: pairs that must change together (e.g. ORM schema ↔ SQL
  mirror) — configured in `proofgate.json` → warn

**Any ❌ = the delivery is NOT done.** Every ⚠️ demands a written justification in
your status report — never silent dismissal.

## Step 2 — the JUDGMENT gate (one by one, with proof)

Answer in writing (in your status report or PR description). An item without
proof is an open item.

1. **Root cause with evidence.** If this fixes a bug: WHAT is the actual cause and
   WHERE is the evidence (error event, log, local repro, query, curl)? Crash or
   failure: in WHICH LAYER does it live (frontend/backend/native/infra)? A
   try/catch in one layer does not catch a crash in another. "Plausible fix"
   in the dark is FORBIDDEN.
2. **VERIFIED ≠ hoped.** List EXPLICITLY: (a) what was actually exercised (request
   against the real server, screenshot reviewed with your own eyes, end-to-end
   round trip, e2e run on the real target) and (b) what was NOT + how it will be.
   If list (a) is empty, the delivery does not exist yet.
3. **Production path traced.** Does the change depend on env/storage/migration/
   config in production? Then the post-deploy smoke test of the REAL flow is done
   or scheduled — "deploy succeeded" proves nothing. DB migration: applied where?
4. **Cross-checked with what is already known?** Re-read your project's known
   issues / state doc BEFORE declaring. Rediscovering a documented problem
   through a user complaint is the maximum embarrassment.
5. **Failed twice on the same thing?** STOP. Don't hammer a third time — step back
   one level, RESEARCH (official docs, search, source), and change the APPROACH.
   Record the change of strategy.
6. **UI changed? Prove it on the real target.** A dev preview is not the product.
   The proof is the real runtime: a browser screenshot of the deployed page, an
   emulator/device run for mobile — reviewed with your own eyes, not assumed.
7. **Touched infra/config/platform? Re-check the obvious.** App name, icons,
   permissions, production env vars, schema parity. The trivial detail is the
   one that humiliates.
8. **Sensitive data on the new path.** Does data added to any payload/log include
   PII (phone, government ID, health, DOB, address)? Is there an adversarial test
   asserting it never leaks?
9. **Brutally honest status.** The final report separates: VERIFIED (with the
   proof) · NOT TESTED (with the why and the how) · PARTIAL (what's missing).
   An inflated status is worse than a bug — it rots trust.

Templates: `templates/evidence-report.md` (status) and `templates/root-cause.md`
(bugfix analysis) — fill them, don't freestyle.

## Step 3 — learn (the self-improvement loop)

If this gate caught something, the lesson becomes DURABLE knowledge NOW:

- a regression test, or
- a new guard in `scripts/guards.d/` (drop a small script — it runs automatically), or
- a line in your project's known-issues doc.

Today's pain is tomorrow's tooling. Re-learning from scratch is forbidden.

## Output template (paste into your status/PR)

```
PROOFGATE — <delivery>
Mechanical: ✅ typecheck ✅ tests ✅ build ✅ pushed ✅ secrets ✅ PII ✅ tests-changed
VERIFIED: <flow X exercised via curl/e2e/screenshot — link/evidence>
NOT TESTED: <what + how it will be>
Root cause (if fix): <layer + evidence>
Lesson recorded: <where> | none
```
