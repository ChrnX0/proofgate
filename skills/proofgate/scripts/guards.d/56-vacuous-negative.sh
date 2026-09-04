#!/usr/bin/env bash
# Guard: an assertion of ABSENCE about a subject that was defaulted to empty, with
# nothing in the same diff asserting the subject is non-empty.
#
# The scar, three times in one day. A test read `(answer.detail ?? []).map(d =>
# d.value).join(' ')` and asserted `doesNotMatch(offered, /price/)`. The day the
# data moved to another field, `detail` became undefined, `offered` became the
# empty string — and the test went on passing. It was not testing anything: an
# absence assertion over nothing is true for free, and it is *green*, which is
# worse than red because nobody looks at it again.
#
# The same shape appeared twice more the same afternoon: a browser check asserting
# a screen did NOT say a word, over a screen dump that could be empty; and a fresh
# guard whose own dictionary loaded as `undefined`, so every comparison failed and
# the first item took the blame for an error that was not its own.
#
# The fix is always one line — assert the subject is non-empty FIRST — and it is
# invisible in review, because the vacuous test looks exactly like the real one.
#
# Fires only inside test files, only when the subject was explicitly defaulted to
# an empty value in the same diff, and only when nothing in that file's added
# lines asserts a length. Narrow on purpose: WARN, never FAIL.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

# A aspa simples entra por variável, e não como `\x27`.
#
# O programa do awk vive dentro de aspas simples do shell, então uma aspa literal
# não cabe nele. O atalho seria `\x27`, que é extensão GNU: no awk do macOS ele
# pode virar o literal "x27" — e aí o guard para de ver `|| ''` **em silêncio**,
# com os testes verdes, porque o caso `?? []` continua casando. Guard que deixa de
# casar caladamente é pior que guard lento, e o teste de portabilidade deste
# repositório não vigia `\x27`. Construir a expressão por concatenação é POSIX e
# não depende de qual awk a máquina tem.
REPORT="$(pg_added_with_file ':(exclude)*.md' | awk -F'\t' -v Q="'" '
  # Only test files: defaulting to empty is ordinary in product code, where it is
  # a fallback and not a claim about coverage.
  $1 !~ /test|spec/ { next }

  {
    file = $1
    line = $2
    n = ++count[file]
    body[file, n] = line

    # A subject defaulted to empty: `const x = a ?? []`, `let y = b || ""`.
    if (line ~ ("(\\?\\?|\\|\\|)[ \t]*(\\[\\]|" Q Q "|\"\"|\\{\\})")) {              # proofgate-allow
      if (match(line, /(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^(const|let|var)[ \t]+/, "", id)
        defaulted[file, id] = 1
      }
    }

    # Anything that proves the subject is not empty. Deliberately generous: one
    # length check anywhere in the file s added lines is enough to say the author
    # thought about it.
    if (line ~ /\.length|toHaveLength|assert_?[Nn]ot[Ee]mpty|refute_empty/) {     # proofgate-allow
      guarded[file] = 1
    }
  }

  END {
    for (key in count) {
      file = key
      if (guarded[file]) continue
      for (i = 1; i <= count[file]; i++) {
        line = body[file, i]
        # The assertions that are true for free over an empty subject.
        if (line !~ /doesNotMatch\(|doesNotInclude\(|notInclude\(|\.not\.toContain|\.not\.toMatch|assert\.ok\([ \t]*!|assertFalse\(|refute[ \t]/) continue   # proofgate-allow
        # ...and only when the subject is one this diff defaulted to empty.
        rest = line
        while (match(rest, /[A-Za-z_$][A-Za-z0-9_$]*/)) {
          word = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if ((file, word) in defaulted) { print file; break }
        }
      }
    }
  }
')"

n="$(printf '%s\n' "$REPORT" | pg_count)"
if [ "${n:-0}" -gt 0 ]; then
  echo "⚠️  vacuous-negative: $n added line(s) assert that something is ABSENT from a subject the same diff defaulted to empty (?? [] / || \"\"), with no length assertion anywhere. Over an empty subject the assertion is true for free — and green. Assert the subject is non-empty first."
  exit 2
fi
echo "✅ vacuous-negative: no absence assertion rides on a possibly-empty subject"
exit 0
