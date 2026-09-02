#!/usr/bin/env bash
# ProofGate stop-guard — a Stop hook that refuses to let the agent declare itself
# DONE while the current HEAD has no fresh, passing verdict. This is the strongest
# and most intrusive layer, so it is OPT-IN and OFF by default: it does nothing
# unless the repo sets "stopGuard": true in proofgate.json (or installs it with
# `install.sh --stop-hook`). The push-guard is the gentle default; this is for
# teams that want "no 'done' without evidence" enforced at the agent boundary.
#
# Contract (Claude Code Stop): reads the event JSON on stdin; printing
# {"decision":"block","reason":"..."} forces the agent to keep working. Respects
# stop_hook_active to avoid an infinite block loop. FAIL-OPEN: any error → allow.
#
# Escape hatches: PROOFGATE_HOOK_OFF=1 · "stopGuard": false/absent (default).
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ "${PROOFGATE_HOOK_OFF:-}" = 1 ] && exit 0
# Already continuing from a previous block → don't loop.
case "$INPUT" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

{
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
  { [ -f "$ROOT/proofgate.json" ] || [ -d "$ROOT/.proofgate" ]; } || exit 0
  # lib.sh, in order: this repo's own source · what install.sh vendored · the copy that
  # ships INSIDE this plugin. The third fallback matters: installed as a Claude Code
  # plugin without ever running install.sh, the first two are absent, `cfg` is undefined,
  # and every hook quietly exits 0 — a guard that silently does nothing is worse than no
  # guard, because the repo believes it is protected.
  PG="$ROOT/skills/proofgate/scripts/lib.sh"
  [ -f "$PG" ] || PG="$ROOT/.proofgate/lib.sh"
  [ -f "$PG" ] || PG="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../skills/proofgate/scripts" 2>/dev/null && pwd)/lib.sh"
  # shellcheck source=/dev/null
  [ -f "$PG" ] && PROOFGATE_CFG="$ROOT/proofgate.json" . "$PG" 2>/dev/null
  command -v cfg >/dev/null 2>&1 || exit 0
  # OPT-IN: do nothing unless explicitly enabled.
  [ "$(cfg '.stopGuard' 2>/dev/null)" = "true" ] || exit 0

  GD="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
  # Prototype mode stands this guard down deliberately — exploration is a legitimate
  # phase, and a tool that refuses to admit that gets bypassed wholesale. It is safe
  # because the mode is impossible to be in unknowingly: a banner every prompt, a line
  # every session start, `mode` in the verdict, claims capped at E1, and the status
  # block prefixed UNVERIFIED PROTOTYPE. The PUSH guard is not relaxed.
  [ -f "$GD/proofgate-mode" ] && exit 0
  V="$GD/proofgate-verdict.json"; HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
  if [ -f "$V" ]; then
    VSHA="$(sed -n 's/.*"sha":"\([0-9a-f]\{7,40\}\)".*/\1/p' "$V" 2>/dev/null | head -1)"
    if [ "$VSHA" = "$HEAD_SHA" ] && grep -q '"pass":true' "$V" 2>/dev/null; then exit 0; fi
  fi


  # requireProof (opt-in): a passing mechanical verdict says "nothing I check is
  # broken", which is not the same as "the claim is proven". Repos that want the
  # stronger contract set requireProof:true and the push waits for the evidence.
  # Pure literal greps — this hook must not depend on a JSON parser.
  if [ "$(cfg '.requireProof' 2>/dev/null)" = "true" ] && [ -f "$V" ]; then
    if grep -q '"proof":{"status":"cannot_prove"' "$V" 2>/dev/null; then
      reason="ProofGate stop-guard: this change requires evidence that cannot be produced on this machine. Say so explicitly in your status — UNPROVEN, and why — rather than implying it was verified."
      printf '{"decision":"block","reason":"%s"}\n' "$(pg_json_escape "$reason")"
      exit 0
    elif grep -q '"proof":{"status":"unproven"' "$V" 2>/dev/null; then
      reason="ProofGate stop-guard: the mechanical gate passed but the central claim is not proven to the level this change requires. Record the run with claim.sh, or state plainly what is NOT verified."
      printf '{"decision":"block","reason":"%s"}\n' "$(pg_json_escape "$reason")"
      exit 0
    fi
  fi

  GATE="bash .proofgate/verify.sh"; [ -f "$ROOT/.proofgate/verify.sh" ] || GATE="the ProofGate verify.sh"
  reason="ProofGate stop-guard: there is no fresh passing verdict for HEAD ${HEAD_SHA:0:7}. Before declaring this done, run \`$GATE\`, make it pass, and walk the judgment gate (SKILL.md step 2). If the gate legitimately cannot pass yet, say what is verified vs not in your status. (Disable: stopGuard:false in proofgate.json.)"
  # Emit the block decision as JSON on stdout.
  printf '{"decision":"block","reason":"%s"}\n' "$(pg_json_escape "$reason")"
  exit 0
} 2>/dev/null || exit 0
exit 0
