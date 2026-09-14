#!/usr/bin/env bash
# Guard: a webhook signature verified against a RE-SERIALIZED body.
# The scar: `X-Hub-Signature-256`, `X-Signature`, Stripe's `Stripe-Signature` and
# friends are an HMAC of the BYTES THAT ARRIVED. Parse the body first
# (`await req.json()`, `request.get_json()`) and hash `JSON.stringify(parsed)` and
# you are comparing the digest of a DIFFERENT text: one space, one key order, one
# unicode escape and the hash moves. The failure is quiet in the worst way — every
# legitimate delivery is rejected, and the "fix" someone reaches for is deleting the
# check, which leaves the endpoint open to anyone on the internet.
# The shape that works: read the body ONCE as text, HMAC that text, and parse the
# JSON out of it.
# Also flagged: `timingSafeEqual` with no length comparison in the file — it THROWS
# on buffers of different lengths, so a forged short signature becomes a 500 (and a
# stack trace) instead of a clean 401.
#
# And the SAME mistake seen from the sending side: an HMAC computed over
# `JSON.stringify(<a variable>)`. The text you sign has to be text you KEPT — sign
# a re-serialization and you cannot reproduce it later. The scar: a webhook retry
# rebuilt the body from a `jsonb` column, and jsonb NORMALIZES (reorders keys,
# strips whitespace), so the digest moved and the subscriber rejected every
# redelivery. Worse, the dev database stored that column as TEXT, where
# parse+stringify round-trips byte-identical by accident — no local test could
# see it, and the defect would debut in production. Bytes that were SIGNED are
# stored as bytes; a JSON column type has license to rewrite what you put in it.
# Signing an inline object literal is fine (nothing to reproduce); signing a
# variable is what this flags.
# Exit: 0 = clean · 2 = WARN.
set -uo pipefail
# shellcheck source=/dev/null
. "${PROOFGATE_LIB:-$(dirname "$0")/../lib.sh}" 2>/dev/null || true

SIG='createHmac|timingSafeEqual|hmac\.new|hmac\.New|HMAC-SHA|x-hub-signature|stripe-signature|x-[a-z0-9-]*signature'  # proofgate-allow
PARSED='(req|request|requisicao|ctx\.req|c\.req)\.json\(\)|request\.get_json\(|await[[:space:]]+[a-z_]*\.json\(\)'     # proofgate-allow
LEN='\.length[[:space:]]*(!==|===|!=|==)'                                                                              # proofgate-allow
# Signing a RE-SERIALIZATION: `.update(JSON.stringify(x))` / `sign(JSON.stringify(x))`
# where x is an identifier. An inline `{`/`[` literal is exempt — there is no earlier
# text to be faithful to.
RESERIAL='(update|sign|assinar|firmar)\([[:space:]]*JSON\.stringify\([[:space:]]*[A-Za-z_$]'      # proofgate-allow

tab="$(printf '\t')"
arquivos=""
while IFS="$tab" read -r file _content; do
  case " $arquivos " in *" $file "*) continue ;; esac
  arquivos="$arquivos $file"
done < <(pg_added_with_file ':(exclude)*.md' ':(exclude)*test*' ':(exclude)*spec*')

reserializa=""; sem_tamanho=""; assina_reserial=""
for file in $arquivos; do
  [ -f "$file" ] || continue
  # The verification may be OLDER than this diff — what changes in a bad commit is
  # often just how the body is read. So the trigger is the FILE's content, not the
  # added lines; the diff only decides which files are in scope.
  grep -Eiq -- "$SIG" "$file" || continue
  if grep -Eq -- "$PARSED" "$file"; then
    pg_ignored "$(pg_fingerprint signature-raw-body "$file" "parsed-body")" \
      && pg_calib signature-raw-body allowed "$file (.proofgateignore)" \
      || reserializa="$reserializa $file"
  fi
  if grep -Eq -- "$RESERIAL" "$file"; then
    pg_ignored "$(pg_fingerprint signature-raw-body "$file" "signs-reserialized")" \
      && pg_calib signature-raw-body allowed "$file (.proofgateignore)" \
      || assina_reserial="$assina_reserial $file"
  fi
  if grep -q 'timingSafeEqual' "$file" && ! grep -Eq -- "$LEN" "$file"; then
    pg_ignored "$(pg_fingerprint signature-raw-body "$file" "no-length-check")" \
      && pg_calib signature-raw-body allowed "$file (.proofgateignore)" \
      || sem_tamanho="$sem_tamanho $file"
  fi
done

if [ -n "$reserializa" ]; then
  echo "⚠️  signature-raw-body: file(s) verify a signature AND read the body with .json():$reserializa"
  echo "    An HMAC covers the bytes received. Read the body once as text, hash THAT text, and"
  echo "    JSON.parse it — re-serializing changes the digest and rejects every real delivery."
  exit 2
fi
if [ -n "$assina_reserial" ]; then
  echo "⚠️  signature-raw-body: file(s) compute an HMAC over JSON.stringify(<variable>):$assina_reserial"
  echo "    You can only reproduce a signature over text you KEPT. Serialize once, sign THAT string,"
  echo "    and store it as text — a json/jsonb column may reorder keys, and the digest moves with it."
  exit 2
fi
if [ -n "$sem_tamanho" ]; then
  echo "⚠️  signature-raw-body: timingSafeEqual with no length check:$sem_tamanho"
  echo "    It THROWS on buffers of different lengths — a forged short signature turns a 401 into a 500."
  exit 2
fi
echo "✅ signature-raw-body: signature checks in the diff hash the raw body"
exit 0
