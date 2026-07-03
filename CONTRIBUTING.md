# Contributing to ProofGate

The best contribution to ProofGate is a **new guard with a scar behind it**:
something that actually shipped broken once — for you, for your team — and that
a 20-line script would have caught at the gate.

## Contributing a guard

1. Copy [`skills/proofgate/scripts/guards.d/TEMPLATE.sh.example`](skills/proofgate/scripts/guards.d/TEMPLATE.sh.example)
   to `NN-your-guard.sh` (the `NN` prefix orders execution).
2. Follow the contract — it's the whole API:
   - read the diff range from `$PROOFGATE_BASE`,
   - print ONE `✅ / ⚠️ / ❌` line,
   - exit `0` (pass) / `1` (fail, blocks the gate) / `2` (warn, must be justified).
   - Optionally `source "$PROOFGATE_LIB"` for the zero-dep helpers: `cfg`/`cfg_len`/
     `cfg_list` (read proofgate.json), and `pg_scan <name> <regex>` (added lines
     matching the pattern, already excluding the gate's own files and suppressions).
3. **Two conventions keep the gate from flagging ITS OWN source** when vendored into
   a consumer repo (guard files literally contain the sin patterns):
   - end pattern-bearing lines with a `proofgate-allow` comment, and
   - exclude the gate's files with `"${PG_SELF_EXCLUDE[@]}"` (from the lib) — or use
     `pg_scan`, which does both for you.
   Consumers get the same escape hatches: a `proofgate-allow` comment on a line, or a
   `guard:file:hash` fingerprint in `.proofgateignore`.
4. Add BOTH test paths to [`tests/run-tests.sh`](tests/run-tests.sh): the guard
   **fires on the sin** and **stays quiet on a clean diff**. A guard that never
   fires is as broken as one that always does — CI enforces this.
5. In the PR description, tell the scar: what shipped broken the day this
   became a rule. (Seriously. It's the project's whole aesthetic.)

## What makes a good guard

- **Low false-positive above all.** One wrong ❌ a week and people alias the
  gate away. Prefer high-signal patterns; use ⚠️ when in doubt; let `--strict`
  users opt into hardness.
- **Fast.** The gate runs before every delivery — a slow guard taxes everyone.
- **Diff-scoped.** Judge what THIS delivery adds, not the whole legacy repo.
- **Self-explaining output.** The one line you print should say what to do next.

## Everything else

Bug fixes, README clarity, new stack auto-detection (verify.sh), translations
of the templates — all welcome. Run the self-tests before pushing:

```sh
bash tests/run-tests.sh
```

And yes — PRs to this repo are expected to fill in the
[Evidence Report](templates/evidence-report.md). The gate gates itself.
