---
description: Run the full ProofGate ritual on the current delivery — mechanical gate, then the judgment gate with evidence, then an optional adversarial skeptic pass. Refuses "done" without proof.
argument-hint: "[--build] [--strict] [--smoke]  (flags passed through to verify.sh)"
allowed-tools: Bash, Read, Grep, Glob, Task
---

You are running the ProofGate acceptance ritual before anything is declared done.
**Golden rule: a checklist without evidence is theater.** Every claim below is
answered with a command that ran, a link, or a number — never "I believe so."

## 1 — Mechanical gate
Run it and read the FULL output (do not trust the exit code alone):

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/verify.sh" $ARGUMENTS
```

(If the repo vendored ProofGate, `bash .proofgate/verify.sh $ARGUMENTS` instead.)
Any ❌ = the delivery is NOT done. Every ⚠️ needs a written justification below —
never a silent dismissal. The machine-readable verdict is at
`.git/proofgate-verdict.json`.

## 2 — Judgment gate (answer each in writing, with proof)
Walk `${CLAUDE_PLUGIN_ROOT}/skills/proofgate/SKILL.md` step 2. In short:
1. **Root cause + layer** (for a fix): what is the real cause, where is the
   evidence, and in which layer does the failure live?
2. **VERIFIED ≠ hoped** — classify the CENTRAL claim on the evidence hierarchy
   (E0 believed → E1 static → E2 test → E3 exercised end-to-end → E4 in prod).
   Done needs **≥ E3**. List what was exercised, and what was not + how it will be.
3. **Production path traced**, **cross-checked known issues**, **failed-twice →
   change approach**, **UI proven on the real target**, **PII on the new path**,
   **brutally honest status** (VERIFIED / NOT TESTED / PARTIAL).

## 3 — Adversarial pass (recommended for anything non-trivial)
Launch the **gate-skeptic** subagent to try to REFUTE your claims against the diff:

> Use the Task tool with subagent_type "gate-skeptic", handing it your status/claims
> and pointing it at the diff. Fold its REFUTED/UNPROVEN findings back in — resolve
> or honestly downgrade each before declaring done.

## 4 — Output
Produce the status block from the SKILL's template: Mechanical (per-check), VERIFIED
(with evidence), NOT TESTED (with the how), Root cause (if a fix), Lesson recorded.
If anything is ❌ or a central claim is below E3, the delivery is **not done** — say
so plainly and name what is left to prove.
