---
description: Turn ProofGate's prototype mode on or off. Relaxes the edit-guard and stop-guard for exploration, never the push, and marks everything produced while it is on.
argument-hint: "on | off | status"
allowed-tools: Bash
---

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/mode.sh" $ARGUMENTS
```

Sometimes you are exploring and the full ceremony is genuinely the wrong price. A tool
that refuses to admit that gets bypassed wholesale, and a bypassed gate protects nothing.
So this mode is real: the edit-guard and stop-guard stand down.

The danger is never the mode — it is forgetting you are in it and then reporting relaxed
work as if it had been gated. So it is loud in four places at once: a banner on every
prompt, a line at every session start, `mode` in the verdict, and claims capped at E1 with
the status block prefixed `UNVERIFIED PROTOTYPE`.

**The push-guard does not stand down.** Exploring is fine; shipping unproven work is the
thing this tool exists to stop. And the mode does not expire on its own — an auto-expiry
would be the silent path.
