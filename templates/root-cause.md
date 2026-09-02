# Root-Cause Analysis — <bug>

> Fill BEFORE writing the fix. A "plausible fix" in the dark is forbidden:
> if you can't point at evidence, you haven't found the cause yet.

## 1. Symptom

- What the user/system observed, verbatim (error text, screenshot, event link):

## 2. Layer

Where does the failure actually live? (Pick one — and prove it. A try/catch in
one layer does not catch a crash in another.)

- [ ] Frontend (JS/rendering)
- [ ] Backend (API/domain logic)
- [ ] Native (mobile platform / OS API)
- [ ] Data (schema/migration/query)
- [ ] Infra (env/config/deploy/network)

Proof of layer: <stack trace line / log source / repro isolating the layer>

## 3. Root cause

- The actual mechanism, one paragraph, with file:line references:

### 3b. The hypothesis, made falsifiable

> Record it rather than only writing it here — a refutation that lives in a document is
> the first thing a context compaction drops, and the dead explanation comes back more
> convincing the second time:
>
> ```sh
> hypothesis.sh open --kind bugfix --symptom "<short stable tag>" \
>   --hypothesis "<the mechanism, one sentence>" \
>   --prediction  "<what MUST exist if that is true>" \
>   --cmd         "<the command that reveals that mark>"
> hypothesis.sh refute <id> --run "<cmd>"     # silence is recorded as "the mark is ABSENT"
> ```
>
> Two refuted explanations for the same `--symptom` escalate the third: the gate then
> demands an adversarial pass, because the third guess about a stubborn symptom is
> exactly where an invented culprit gets written down and hardens into folklore.


Observing an EFFECT is not identifying an AGENT. Before this cause goes anywhere
durable, state what would have to be true — then go look.

| | |
|---|---|
| **Hypothesis** (the mechanism, one sentence) | |
| **Prediction** — if true, what MUST exist? (a log line, a process, a reflog entry, a metric, a stack frame) | |
| **Command** that reveals it | |
| **What it actually printed** | |

- [ ] The predicted mark **is present** → the hypothesis survives.
- [ ] The mark is **absent** → the hypothesis is dead. Replace it; do not patch it.

**If the cause is EXTERNAL** (infra, platform, a third party, "it's flaky"), the bar goes
UP, not down: nothing contradicts an absent culprit, so it is never disproven and hardens
into folklore that future decisions orbit. With no artifact naming the agent, write
**"effect observed; cause unknown"** plus the command that will measure it next time — an
open question beats a comfortable wrong answer.

## 4. Evidence

- <error-tracker event link / log excerpt / failing test / query result>

## 5. Why it wasn't caught earlier

- <missing test? missing guard? known issue ignored? new failure mode?>

## 6. The fix

- What changes, and why this kills the CAUSE (not the symptom):

## 6b. Counter-proof

- What would you expect to see if this fix were WRONG (the symptom still firing,
  a different error, the wrong value)? Did you check that signal is now ABSENT?
  A fix you only confirmed by its absence of the happy-path error isn't proven.

## 7. Regression pin

- Test/guard added so this exact failure can never ship silently again:

## 8. Strike counter

- Is this the 2nd+ attempt at this same bug? If yes: what APPROACH changed this
  time? (Hammering the same strategy a third time is forbidden.)
