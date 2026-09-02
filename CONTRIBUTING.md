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
   - Optionally `source "$PROOFGATE_LIB"` for the zero-dep helpers:
     `cfg`/`cfg_len`/`cfg_list` (read proofgate.json), `pg_scan <name> <regex>` (added
     lines matching the pattern, already excluding the gate's own files and
     suppressions), `pg_added_lines [pathspecs...]` (every added line, same exclusions),
     `pg_count`/`pg_lines` (counts that are 0 rather than empty), and `pg_sha1`.
   - **Use `pg_scan` or `pg_added_lines` rather than calling `git diff` yourself.** Not
     for tidiness: guards that build their own range silently opt out of LIVE mode, so
     they cannot run at the moment of the edit (`liveGuards`) — only at the gate. Three
     guards had hand-rolled the identical pipeline and were invisible there until 2.10.
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
   If you touched anything the protocol walks through — a ledger, a hook, the engine —
   also run [`tests/acceptance.sh`](tests/acceptance.sh), which drives the whole thing
   end to end in a real repository. It exists because three real defects passed a fully
   green unit suite: every piece behaved as specified and the path between them did not
   work.
5. Update the guard count where the docs state it — a test compares it against
   `ls guards.d` and fails on drift, because a number a human maintains by hand drifts.
6. In the PR description, tell the scar: what shipped broken the day this
   became a rule. (Seriously. It's the project's whole aesthetic.)

## What makes a good guard

- **Low false-positive above all.** One wrong ❌ a week and people alias the
  gate away. Prefer high-signal patterns; use ⚠️ when in doubt; let `--strict`
  users opt into hardness.
- **Fast.** The gate runs before every delivery — a slow guard taxes everyone.
- **Diff-scoped.** Judge what THIS delivery adds, not the whole legacy repo.
- **Self-explaining output.** The one line you print should say what to do next.

## Contributing anywhere else in the engine

Two conventions hold outside `guards.d/` as well:

- **Every ledger write goes through `pg_ledger_append`.** It carries the hash of the
  previous row, so a line written by hand breaks the chain and the `ledger-chain` check
  FAILs. That is tamper-*evident*, not tamper-proof — anything with a shell can recompute
  a chain — and the point is to remove the cheap, deniable edit.
- **Any value read back out of a ledger to be EXECUTED goes through `pg_json_field`**,
  never `grep`. Stored commands are JSON-escaped; running the escaped form means running
  a different command from the one you are checking. The obvious fix — a few
  substitutions reversing the escape — is also wrong, because `\\n` matches the newline
  rule first. Undoing an escape needs a parser.

Portability is not optional: CI runs macOS, so bash 3.2 and BSD userland. No
`declare -A`, `mapfile`, `sed -i`, `date -d`, `grep -P`, `xargs -r`, or `flock` — a test
greps for all of them. Hash things with `pg_sha1` (`git hash-object`), never `sha1sum`.

## Everything else

Bug fixes, README clarity, new stack auto-detection (verify.sh), translations
of the templates — all welcome. Run the self-tests before pushing:

```sh
bash tests/run-tests.sh      # 246 cases: guards, engine, hooks, ledgers, scripts
bash tests/acceptance.sh     # 18 steps: the whole protocol, in a real repo
shellcheck -S warning skills/proofgate/scripts/*.sh skills/proofgate/scripts/guards.d/*.sh hooks/*.sh install.sh tests/*.sh
```

And yes — PRs to this repo are expected to fill in the
[Evidence Report](templates/evidence-report.md). The gate gates itself.
