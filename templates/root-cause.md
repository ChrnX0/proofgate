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
