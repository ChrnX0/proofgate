---
description: Print the delivery status block, GENERATED from the claims ledger and the verdict — never typed. Use this as the status you paste into a PR or hand back to the user.
argument-hint: "[--sha <sha>]"
allowed-tools: Bash
---

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/claim.sh" render $ARGUMENTS
```

(Vendored: `bash .proofgate/claim.sh render`.)

Paste the output verbatim. **Do not write your own version of this block, and do not
"improve" its wording** — the entire point is that every line traces to a row someone
can re-run. A status you compose by hand is E0 by construction: nothing produced it.

If it says `VERIFIED: NOTHING`, that is the honest state of the delivery, not a
formatting problem. Record the claims first.
