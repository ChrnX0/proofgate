# Evidence Report — <delivery name>

> Paste this filled-in block into your PR description or status update.
> Rule: every claim needs a command that ran, a link, or a number.
> An empty VERIFIED section means the delivery does not exist yet.

## Status block (generated — do not retype)

```
<paste the output of `claim.sh render` verbatim>
```

That block is assembled from the verdict, the blast radius and the claims ledger. If it
says `VERIFIED: NOTHING`, record the claims first — `claim.sh add --run "<cmd>"` — rather
than describing the work in prose here. Prose is E0.

## Mechanical gate

```
<paste the tail of `verify.sh` output — the ✅/⚠️/❌ lines and the verdict>
```

Justification for each ⚠️ (mandatory — silence is not a justification):

- ⚠️ `<warning>` → <why it is acceptable HERE, or the issue that tracks it>

## VERIFIED (exercised for real)

> Evidence levels are defined once, in `skills/proofgate/SKILL.md` § the evidence
> hierarchy. Short form: **E0** believed · **E1** static · **E2** automated test ·
> **E3** exercised end-to-end on the real runtime · **E4** observed in production.
> A runtime claim is DONE only at **E3+**, and the level comes from `claim.sh`, which
> ran the command — not from this table being filled in optimistically.

| Claim | Level | Evidence |
|---|---|---|
| e.g. "POST /api/orders returns 201 in production" | E4 | `curl` output / prod log link |
| e.g. "the checkout flow works" | E3 | e2e run URL / screenshot reviewed |
| e.g. "the reducer handles the empty case" | E2 | test name + pass line |

## NOT TESTED (honest list)

| What | Why not | How/when it will be verified |
|---|---|---|
| | | |

## PARTIAL / KNOWN GAPS

- <what is intentionally missing and where that is tracked>

## Root cause (bugfix deliveries only)

See `root-cause.md` template — link the filled analysis here.

## Lesson recorded

- <regression test / new guard in guards.d / known-issues entry> — or "none, nothing caught".
