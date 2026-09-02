---
description: Show which guards are earning the noise they make — how often each fired, how often it was suppressed, and whether any recorded incident ever credited it. Reports only; it never changes configuration.
allowed-tools: Bash
---

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/verify.sh" --calibration
```

Every guard trades signal against noise, and the trade is invisible from inside any one
run. A guard that fires constantly and is suppressed every single time is not protecting
anything — it is teaching the team to reach for the escape hatch, and that habit does not
stay local to the guard that taught it.

| Column | Meaning |
|---|---|
| **fired** | produced a finding |
| **allowed** | someone silenced one (`proofgate-allow`, `.proofgateignore`, a severity override) |
| **scars** | a recorded incident credited this guard as what would have caught it |

High `allowed` with zero `scars` is the demotion signal. Low `fired` is not a problem —
a guard that never fires costs nothing and is one bad day from being the reason you still
have a job.

**Nothing here edits `proofgate.json`.** A tool that quietly turned its own checks off
after enough suppressions would be automating exactly the erosion it exists to measure.
Demoting a guard is a decision for a person, made with this table in front of them.
