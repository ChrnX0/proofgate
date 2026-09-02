---
description: Test a hypothesis in its own git worktree, where it cannot leave anything behind — and record the result against that hypothesis automatically. Several ideas can run at once, because they no longer share a working tree.
argument-hint: "<h-id> [--dirty] [--in-place] -- <command>   |   --parallel <h-id>::<cmd> <h-id>::<cmd>"
allowed-tools: Bash
---

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/proofgate/scripts/experiment.sh" $ARGUMENTS
```

Testing an idea means changing something, running, and changing it back — and *changing
it back* is where this goes wrong. Three experiments in a row leave a working tree nobody
can characterise, and the classic ending is a "fix" that only works because of a leftover
from experiment two. Each run here gets its own worktree and is cleaned up.

- `--dirty` carries your uncommitted work into the worktree. Without it, an experiment
  about the change you are making runs against the code as it was *before* you made it.
- `--parallel` runs several at once — the isolation is what makes that safe.
- `--in-place` for cases a worktree cannot serve. It hashes the tree before and after and
  records `tree-mutated` if the run changed anything, because a result from a run that
  altered the tree describes a state that no longer exists.

**It never closes the hypothesis for you.** An experiment produces an observation; what
that observation *means* is the judgment this tool refuses to fake. Close it yourself
with `hypothesis.sh refute` or `confirm`.
