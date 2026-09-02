---
description: Seal this delivery's evidence to the commit as a git note, so a reviewer can check it instead of taking your word for it — and verify or replay a sealed bundle.
argument-hint: "seal [--push] | verify [<sha>] | replay [<sha>]"
allowed-tools: Bash
---

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/proof.sh" $ARGUMENTS
```

Everything the gate produces lives in `.git/` and is local. The person reviewing your
pull request sees a description that *claims* a gate ran, and has two options: believe
it, or re-do the work. That is the same trust-me problem this whole tool exists to
remove, one level up.

`seal` bundles the verdict, the blast radius, the claims for this commit, the skeptic
record and the claim-linked audit segment, hashes each part, and attaches it to the
commit under `refs/notes/proofgate`. It does not change the commit, and `--push` sends
it with the code.

**What it proves, exactly.** That the local gate saw these commands run with these exit
codes and these output hashes. It does **not** prove the local gate was honest — anything
with a shell can write a ledger and seal it. `verify` catches tampering *after* sealing;
`replay` re-runs the recorded commands and downgrades the bundle in place if the evidence
no longer reproduces. The independent check is CI running the gate itself; the note is
what makes the two comparable.

The note deliberately does not survive an amend or rebase. Evidence about the old commit
is not evidence about the new one, and losing it there is correct.
