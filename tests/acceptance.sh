#!/usr/bin/env bash
# ProofGate — END-TO-END ACCEPTANCE. The whole protocol, driven in a fresh repository the
# way a user drives it, on the real runtime.
#
# run-tests.sh proves the pieces. This proves the PATH THROUGH them, and the difference
# is not academic: the first version of this script failed four of its eighteen steps
# against a unit suite that was entirely green. Claims were keyed to the HEAD sha at the
# moment they were recorded, so `git commit` orphaned every claim made before it — the
# natural order of work (do it, prove it, commit it, gate it) produced a delivery whose
# evidence had silently vanished, and the status rendered VERIFIED: NOTHING with a full
# ledger on disk. No unit test could have seen it, because each piece was behaving
# exactly as specified.
#
# That is what this file is for, and why it is the E3 evidence for ProofGate's own
# deliveries: the gate demands that a runtime claim be exercised on the real thing, and
# for a tool made of shell scripts and git, "the real thing" is a real repository with a
# real remote, driven end to end.
#
#   bash tests/acceptance.sh        # 18 steps · exits non-zero on the first failure
set -uo pipefail
PG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"; cd "$W" || exit 1
R="$(mktemp -d)"; git init -q --bare "$R"
git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src
cat > src/expiry.ts <<'EOF'
export function isExpired(tokenAgeMs: number): boolean { return tokenAgeMs > 3600; }
EOF
cat > src/expiry.test.sh <<'EOF'
#!/bin/sh
grep -q '3600 \* 1000' src/expiry.ts
EOF
chmod +x src/expiry.test.sh
cat > proofgate.json <<'EOF'
{"commands":{"typecheck":"true","lint":"true","test":"true","e2e":"true"},
 "editGuard":true,"liveGuards":true,"audit":true,"requireProof":true}
EOF
git add -A && git commit -qm base
git remote add origin "$R" && git push -qu origin main
git checkout -qb fix/token-expiry
export PROOFGATE_LIB="$PG/skills/proofgate/scripts/lib.sh"
S="$PG/skills/proofgate/scripts"; H="$PG/hooks"
STEP=0; FAILED=0
ok()  { STEP=$((STEP+1)); printf '  %2d ✅ %s\n' "$STEP" "$1"; }
bad() { STEP=$((STEP+1)); printf '  %2d ❌ %s\n' "$STEP" "$1"; FAILED=$((FAILED+1)); }
chk() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want [$1] got [$2])"; fi; }

echo "1. preflight on an untouched branch"
bash "$S/impact.sh" --base origin/main </dev/null >/dev/null 2>&1
chk L1 "$(grep -o '"risk_class":"[^"]*"' .git/proofgate-impact.json | sed 's/.*:"//;s/"//')" "nothing changed yet → L1"

echo "2. open the hypothesis, then try to edit source"
bash "$S/hypothesis.sh" open --kind bugfix --symptom token-expiry \
  --hypothesis "expiry is compared in seconds while the input is milliseconds" \
  --prediction "the test asserting a ms threshold fails" --cmd "sh src/expiry.test.sh" </dev/null >/dev/null 2>&1
HID="$(bash "$S/hypothesis.sh" list --open </dev/null 2>/dev/null | awk '{print $1}' | head -1)"
c=0; printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/expiry.ts"}}' "$W" | bash "$H/edit-guard.sh" >/dev/null 2>&1 || c=$?
chk 2 "$c" "edit-guard blocks the fix before a red test exists"

echo "3. record the RED test, then edit is allowed"
bash "$S/claim.sh" add --kind red-test --hypothesis "$HID" --run "sh src/expiry.test.sh" </dev/null >/dev/null 2>&1
c=0; printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/expiry.ts"}}' "$W" | bash "$H/edit-guard.sh" >/dev/null 2>&1 || c=$?
chk 0 "$c" "with the red test recorded, the edit is allowed"

echo "4. a pasted secret is caught at edit time, not at the gate"
printf 'export function isExpired(a: number){ return a > 3600; }\nconst k = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";\n' > src/expiry.ts
N="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/expiry.ts"}}' "$W" | bash "$H/edit-notice.sh" 2>/dev/null)"
if printf '%s' "$N" | grep -q 'secrets:'; then ok "live guard reports the credential immediately"; else bad "live guard missed the credential"; fi

echo "5. make the fix, prove red→green with the SAME command"
cat > src/expiry.ts <<'EOF'
export function isExpired(tokenAgeMs: number): boolean { return tokenAgeMs > 3600 * 1000; }
EOF
RED="$(bash "$S/claim.sh" list </dev/null 2>/dev/null | grep red-test | awk '{print $1}' | head -1)"
bash "$S/claim.sh" add --kind green-test --same-as "$RED" --run "sh src/expiry.test.sh" </dev/null >/dev/null 2>&1
chk 1 "$(bash "$S/claim.sh" list </dev/null 2>/dev/null | grep -c green-test)" "green test recorded against the same command"
bash "$S/hypothesis.sh" confirm "$HID" --run "sh src/expiry.test.sh" </dev/null >/dev/null 2>&1

echo "6. the central E3 claim needs a marker unique to the new version"
c=0; bash "$S/claim.sh" add --claim "the ms threshold is live" --level E3 --run "cat src/expiry.ts" </dev/null >/dev/null 2>&1 || c=$?
chk 2 "$c" "E3 without --expect is refused"
bash "$S/claim.sh" add --claim "the ms threshold is live" --level E3 --run "cat src/expiry.ts" --expect '3600 \* 1000' </dev/null >/dev/null 2>&1
chk E3 "$(bash "$S/claim.sh" achieved </dev/null 2>/dev/null)" "central claim earned E3"

echo "7. the gate"
git add -A && git commit -qm "fix: compare token expiry in milliseconds"
bash "$S/verify.sh" --base origin/main </dev/null >/tmp/acc-gate.out 2>&1; GC=$?
chk 0 "$GC" "mechanical gate passes"
if grep -q 'proof-level: central claim at E3' /tmp/acc-gate.out; then ok "proof-level satisfied"; else bad "proof-level not satisfied"; fi
chk 1 "$(grep -o '"sha":"' .git/proofgate-verdict.json | wc -l | tr -d ' ')" "verdict keeps exactly one sha (hook contract)"

echo "8. push is gated on a FRESH verdict"
c=0; printf '{"tool_name":"Bash","tool_input":{"command":"git push origin fix/token-expiry"}}' | bash "$H/push-guard.sh" >/dev/null 2>&1 || c=$?
chk 0 "$c" "push allowed with a fresh passing verdict"
echo "// touch" >> src/expiry.ts; git add -A && git commit -qm touch
c=0; printf '{"tool_name":"Bash","tool_input":{"command":"git push origin fix/token-expiry"}}' | bash "$H/push-guard.sh" >/dev/null 2>&1 || c=$?
chk 2 "$c" "push blocked after the code moved past the verdict"
git reset -q --hard HEAD~1

echo "9. seal, verify, tamper, replay"
bash "$S/verify.sh" --base origin/main </dev/null >/dev/null 2>&1
bash "$S/proof.sh" seal </dev/null >/dev/null 2>&1
chk verified "$(bash "$S/proof.sh" verify </dev/null 2>/dev/null)" "sealed bundle verifies"
git notes --ref=refs/notes/proofgate show HEAD | sed 's/"pass":true/"pass":false/' | git notes --ref=refs/notes/proofgate add -f -F - HEAD >/dev/null 2>&1
V="$(bash "$S/proof.sh" verify </dev/null 2>/dev/null)"
if printf '%s' "$V" | grep -q tampered; then ok "an edited note is detected"; else bad "tampering not detected"; fi
git notes --ref=refs/notes/proofgate remove HEAD >/dev/null 2>&1
bash "$S/proof.sh" seal </dev/null >/dev/null 2>&1
RP="$(bash "$S/proof.sh" replay </dev/null 2>&1)"
if printf '%s' "$RP" | grep -q "reproduces"; then ok "recorded evidence replays"; else bad "replay failed: $RP"; fi

echo "10. the ledger cannot be hand-written"
printf '{"id":"c-forged","sha":"%s","kind":"central","level_recorded":"E4","prev":"deadbeef"}\n' "$(git rev-parse HEAD)" >> .git/proofgate-claims.jsonl
bash "$S/verify.sh" --base origin/main </dev/null >/tmp/acc-forge.out 2>&1; FC=$?
chk 1 "$FC" "a forged ledger row fails the gate"
if grep -q ledger-chain /tmp/acc-forge.out; then ok "ledger-chain names the broken line"; else bad "ledger-chain silent"; fi

echo "11. the report is rendered from the ledger"
RND="$(bash "$S/claim.sh" render </dev/null 2>&1)"
if printf '%s' "$RND" | grep -q 'sh src/expiry.test.sh'; then ok "the status quotes the command that ran"; else bad "render lost the evidence"; fi

echo
if [ "$FAILED" = 0 ]; then echo "ACCEPTANCE: $STEP/$STEP passed"; else echo "ACCEPTANCE: $FAILED of $STEP FAILED"; fi
cd /; rm -rf "$W" "$R"
exit "$FAILED"
