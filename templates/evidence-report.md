# Evidence Report — <delivery name>

> Paste this filled-in block into your PR description or status update.
> Rule: every claim needs a command that ran, a link, or a number.
> An empty VERIFIED section means the delivery does not exist yet.

## Mechanical gate

```
<paste the tail of `verify.sh` output — the ✅/⚠️/❌ lines and the verdict>
```

Justification for each ⚠️ (mandatory — silence is not a justification):

- ⚠️ `<warning>` → <why it is acceptable HERE, or the issue that tracks it>

## VERIFIED (exercised for real)

| Claim | Evidence |
|---|---|
| e.g. "POST /api/orders returns 201 in production" | `curl` output / screenshot link / e2e run URL |
| e.g. "UI renders on the real target" | screenshot reviewed, link |

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
