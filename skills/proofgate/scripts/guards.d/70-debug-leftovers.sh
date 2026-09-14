#!/usr/bin/env bash
# Guard: debug leftovers in the diff.
# `.only` on a test is the sneakiest one: it silently disables the REST of the
# suite — CI goes green because almost nothing ran. That one is a hard FAIL.
# `debugger` / stray `console.log` / fresh TODOs are warnings to justify.
# Exit: 0 = clean · 1 = FAIL (.only/focused tests) · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true
# The range now comes from pg_added_lines (which reads PROOFGATE_BASE itself); this
# assertion stays because the contract still requires the variable to be set.
# shellcheck disable=SC2034
BASE="${PROOFGATE_BASE:?}"

# Via the shared helper, so this guard also works in LIVE mode (the edit-notice hook
# runs it against the working tree the moment a file is written). A `.only` is cheapest
# to catch in the ten seconds after typing it, not at the gate.
ADDED="$(pg_added_lines '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs')"

FOCUS=$(echo "$ADDED" | grep -Ec '\b(it|test|describe)\.only\(|\bf(describe|it)\(' || true)
if [ "${FOCUS:-0}" -gt 0 ]; then
  echo "❌ debug-leftovers: $FOCUS focused test(s) added (.only/fdescribe/fit) — the rest of the suite is silently OFF. Green CI would be a lie."
  exit 1
fi

DEBUGS=$(echo "$ADDED" | grep -Ec '\bdebugger\b|console\.log\(|binding\.pry|breakpoint\(\)' || true)
# A marca tem que PARECER uma marca, e isto e cicatriz de um repositorio real.
#
# `\b(TODO|FIXME|HACK)\b` casa a PALAVRA, e em portugues e espanhol "todo" e uma
# palavra comum — "todo o movimento", "apaga TODO o livro-razao", escrito em
# maiuscula por enfase. Num commit do ChrnX0/Norva o guard acusou tres marcas
# frescas e as tres eram prosa: um comentario em portugues, uma frase de erro e um
# docblock. Nenhuma linha de codigo tinha marcador nenhum.
#
# Isso nao e ruido inofensivo. Um guard que acusa o que nao existe ensina a
# ignorar o que ele diz — e ai o TODO de verdade passa junto, no dia em que
# alguem lê "3 fresh TODO" e ja sabe que sao falsos. E a mesma doenca que este
# repositorio chama de alerta inventado, do lado da ferramenta.
#
# Marcador de verdade tem uma de duas formas: vem logo depois de um abridor de
# comentario (// # /* * --), ou e seguido de dois pontos ou parentese —
# `TODO:`, `TODO(alice):`. Palavra solta no meio de uma frase nao e marcador em
# lingua nenhuma.
#
# O que isto DEIXA de pegar, dito em vez de omitido: `"TODO fix this"` dentro de
# uma string, sem abridor e sem dois pontos. E raro, e nao e marcador de codigo —
# e o preco de nao alarmar em toda linha escrita em portugues.
#
# E o `^\+?` nao e enfeite: `pg_added_lines` devolve as linhas COM o `+` do diff
# na frente. Uma ancora de inicio de linha num guard significa, na pratica,
# "depois do mais" — e sem o `\+?` um `# FIXME` na primeira coluna deixava de
# casar EM SILENCIO, com o teste do `// TODO:` passando por outro caminho e
# escondendo o buraco. Foi assim que este proprio ajuste quase entrou pela metade.
MARCA='(^\+?|[[:space:]])(//|#|/\*|\*|--)[[:space:]]*(TODO|FIXME|HACK)\b|\b(TODO|FIXME|HACK)[[:space:]]*[:(]'  # proofgate-allow
TODOS=$(echo "$ADDED" | grep -Ec "$MARCA" || true)
if [ "$((${DEBUGS:-0} + ${TODOS:-0}))" -gt 0 ]; then
  echo "⚠️  debug-leftovers: ${DEBUGS:-0} debug statement(s) + ${TODOS:-0} fresh TODO/FIXME in the diff — shipping them? justify in your status"
  exit 2
fi
echo "✅ debug-leftovers: no focused tests, debug statements or fresh TODOs added"
exit 0
