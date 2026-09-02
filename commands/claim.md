---
description: Record a claim about this delivery WITH the command that proves it — claim.sh runs it, captures the exit code and output hash, and writes a hash-chained ledger row. A level above E0 cannot be recorded without something having actually run.
argument-hint: "add --claim \"<text>\" --level E3 --run \"<cmd>\" --expect \"<marker>\"  |  list  |  show <id>"
allowed-tools: Bash
---

Record evidence for the current delivery. The level is not something you type — it is
what the run supports.

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/claim.sh" $ARGUMENTS
```

(Vendored: `bash .proofgate/claim.sh $ARGUMENTS`.)

**The shapes that matter**

| Situation | Command |
|---|---|
| The bug reproduces (do this BEFORE the fix) | `add --kind red-test --run "<the test>"` — refused if it passes |
| The fix works | `add --kind green-test --same-as <red-id> --run "<the SAME test>"` |
| The central runtime claim | `add --claim "..." --level E3 --run "<drive the real flow>" --expect "<marker unique to the NEW build>"` |
| Something you did NOT verify | `add --kind gap --claim "the concurrent path is not exercised"` |

**Why it refuses things.** `--run "true"`, `npm test || true`, `... ; exit 0` are rejected:
a command whose exit status cannot change proves nothing about the world. E3 and E4
require `--expect` because a 200, or a string the old build also served, is compatible
with your change never having deployed. A `--kind red-test` that passes is rejected
because a test that was never red has never shown it can see the bug.

If a run fails or the marker is absent, the row is still written — at **E0**, with the
reason. That record is the useful one: it is the difference between "not verified" and
"verified" surviving into the status instead of being smoothed over.
