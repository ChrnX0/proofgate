---
description: Run the full ProofGate ritual on the current delivery — mechanical gate, then the judgment gate with evidence, then an optional adversarial skeptic pass. Refuses "done" without proof.
argument-hint: "[--build] [--strict] [--smoke]  (flags passed through to verify.sh)"
allowed-tools: Bash, Read, Grep, Glob, Task
---

You are running the ProofGate acceptance ritual before anything is declared done.
**Golden rule: a checklist without evidence is theater.** Every claim below is
answered with a command that ran, a link, or a number — never "I believe so."

## 0 — Blast radius (what this change can break)
`verify.sh` computes it first and prints one `impact:` line. Read it before anything
else and say it out loud in your status: the **risk class** (L1 docs/tests · L2 source
with callers · L3 auth/money/migration/crypto), the **evidence level it requires**
(L1 → E1, otherwise **E3**), and the **navigation confidence**. Low confidence means
callers came from a grep, not a symbol table — treat the caller list as a floor, not a
census. The full measurement is at `.git/proofgate-impact.json`; `--slice` writes the
skeptic's reading scope.

If the radius says **L3**, an adversarial pass is not optional (step 3).

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

## 3 — Adversarial pass, sized to the blast radius

First write the scope the skeptics will read (the diff plus the first-degree callers of
every changed symbol, plus the tests that touch them):

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/impact.sh" --slice
```

Then launch the panel **in proportion to the risk class from step 0** — cost that does
not scale with risk is cost people learn to skip:

| Class | Who runs |
|---|---|
| **L1** (docs, tests, config) | nobody. Ceremony for a README edit teaches everyone the ceremony is noise. |
| **L2** (source with callers) | `gate-skeptic` |
| **L3** (auth · money · migrations · crypto · permissions) | `gate-skeptic` + `intent-skeptic` + `security-skeptic` |

Use the Task tool with the matching `subagent_type`, pointing each at
`.git/proofgate-slice.md`. Each must emit one line per finding:
`VERDICT <claim-id|-> :: <evidence> :: repro: <cmd|->`.

Pipe every agent's output through the recorder — do not fold the findings in by hand:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/skeptic.sh" record --agent gate-skeptic < findings.txt
```

**It re-runs every claimed repro.** A REFUTED whose command exits 0, or that carries no
command, is downgraded to UNPROVEN and the downgrade is recorded. That symmetry is the
point: a skeptic writing "REFUTED: this probably breaks under load" has produced an E0
claim, and because it sounds rigorous it gets trusted more than the claim it refuted —
the same failure the skeptic exists to catch, wearing the other costume, and more
expensive, because it sends people to fix what was never broken.

What survives as REFUTED is real: a command that fails today on this diff. Fix it.

## 4 — Output: render it, do not write it

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/claim.sh" render
```

Paste that verbatim as your status. **Do not compose your own version of it.** Every line
in the rendered block traces to a row someone can re-run; a block you write by hand is E0
by construction, because nothing produced it. If it prints `VERIFIED: NOTHING`, that is
this delivery's real state — record the claims (`/proofgate:claim`) rather than
describing the work in prose.

If anything is ❌, or the central claim is below what the blast radius requires, the
delivery is **not done**. Say so plainly and name exactly what is left to prove.
