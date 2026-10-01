#!/usr/bin/env bash
# Guard: an error swallowed on the same line it is caught.
# The scar: `catch (e) {}` / `except: pass` / `rescue nil` on a money, auth, or
# write path turns a real failure into a green screen — the payment silently
# didn't go through, the token silently didn't rotate, and you find out from the
# user. This flags only the SINGLE-LINE empty handler (the deliberate mute); a
# multi-line body with real handling is out of scope.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# A sin has to BE code, not a sentence about code — and this is a scar from a real repo.
#
# In ChrnX0/Norva the guard reported "2 added line(s) swallow an error" on a branch whose
# diff contained ZERO muted handlers. Both hits were docblock prose: lines that write the
# words `catch {}` precisely to say *"this is NOT the `catch {}` this house calls a
# disease"*. The `:(exclude)*.md` pathspec does not help — a docblock lives in the .ts.
#
# It is the same disease 70-debug-leftovers was cured of, with the same repo as the
# witness: a guard that accuses what is not there teaches you to ignore what it says, and
# then the real muted catch rides in behind a warning nobody reads any more. The sibling
# fixed it by demanding the MARKER form; the inverse is needed here — reject when a
# comment opener comes first.
#
# The shape: after optional leading space, the first character must not open a comment
# (`*` for a jsdoc continuation, `//`, `/*`, `#`, `--`). Two alternatives and not one
# because the sin can BEGIN the line — `except: pass` in Python does — and a
# prefix class that consumes a character would eat the `e` and never match again. So:
# either the sin starts right there, or a non-opener character starts the line and the
# sin comes later on it.
#
# `\+?` is defensive, not decoration: pg_added_with_file strips the diff's `+`
# (`l=substr($0,2)`), but a line anchor in a guard means "after the plus" in the sibling
# helper, and a guard that silently stops matching if the helper changes is the failure
# this repository charges most for.
#
# What this DELIBERATELY still flags, said rather than hidden: an empty catch inside a
# string on a code line (`node -e '...}catch(e){}'`). It IS an empty handler; whether it
# is justified is what the warning asks. Only prose is excused.
SIN='(catch[[:space:]]*(\([^)]*\))?[[:space:]]*\{[[:space:]]*\}|except[^:]*:[[:space:]]*pass[[:space:]]*$|rescue[[:space:]]+nil[[:space:]]*$|rescue[[:space:]]*=>[[:space:]]*[[:alnum:]_]+[[:space:]]*$)'  # proofgate-allow
PAT="^\\+?[[:space:]]*($SIN|[^[:space:]*/#-].*$SIN)"  # proofgate-allow
n="$(pg_scan silent-catch "$PAT" ':(exclude)*.md' | pg_count)"
if [ "${n:-0}" -gt 0 ]; then
  echo "⚠️  silent-catch: $n added line(s) swallow an error with no handling (empty catch / except: pass / rescue nil). On a money/auth/write path this hides real failures — handle or log it."
  exit 2
fi
echo "✅ silent-catch: no muted error handlers added"
exit 0
