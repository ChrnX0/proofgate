---
description: Start a delivery the way it should end — measure the blast radius, recall what the project already knows about these files, name the observation that will prove it done, and open a falsifiable hypothesis before writing any code.
argument-hint: "[--base <ref>]  (optional diff base)"
allowed-tools: Bash, Read, Grep, Glob
---

Run this BEFORE writing code. Every step below exists because doing it afterwards is
either impossible or dishonest.

## 1 — Measure what this can break

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/impact.sh" $ARGUMENTS --json
```

Read `risk_class`, `required_level` and `max_achievable_level`. If the level this change
will owe is not reachable on this machine, you know that **now** — while there is still
time to configure `commands.e2e` or agree the claim will be UNPROVEN — instead of at the
end, as an excuse.

## 2 — Recall what is already known

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/memory.sh" recall --changed
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/hypothesis.sh" brief
```

Facts anchored to the files you are about to touch, and explanations already ruled out.
**Treat both as hypotheses, not as truth**: memory carries the blob it was anchored to,
and a `stale` marker means the code moved underneath it. Re-verify before relying on it.

## 3 — Name the proof first

Write down the ONE observation that will prove this done — the E3 command, with the
marker unique to the new version. If you cannot name it, you do not understand the task
yet, and no amount of code will fix that. Designing toward that observation is what
stops the work from drifting toward "it looks right".

## 4 — State the mechanism, falsifiably

For a fix:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/hypothesis.sh" open --kind bugfix \
  --symptom "<short stable tag for the SYMPTOM>" \
  --hypothesis "<the mechanism, one sentence>" \
  --prediction "<what MUST exist if that is true>" \
  --cmd "<the command that reveals that mark>"
```

Then **run the command and read it**. If the mark is absent, the hypothesis is dead —
`hypothesis.sh refute <id> --run "<cmd>"`. Do not patch it; replace it.

The `--symptom` tag is what makes the third attempt different from the first: once the
same symptom has survived two refuted explanations, the next hypothesis on it is
escalated, the gate demands an adversarial pass, and "effect observed, cause unknown"
becomes the honest record instead of a third confident guess.

For a feature, `--kind feature` with the intent as the hypothesis: it is what the
intent-skeptic later checks the diff against.
