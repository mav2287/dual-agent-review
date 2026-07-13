#!/usr/bin/env bash
# Stop hook — the automatic engine. After Claude responds, it HARD-VERIFIES that an
# actual `dar ripple` review ran for the current high-blast working state before
# letting Claude finish. It does NOT self-satisfy: it releases a high-blast change
# only when a review RECEIPT (written by dar ripple, keyed to the exact diff incl.
# untracked content) matches the current state. Fixing findings changes the diff,
# which invalidates the receipt and forces a fresh review.
#
# Fail-secure: changes present but unmeasurable (node/probe down) → block (advisory,
# once per turn, since no receipt can clear an unmeasurable state). DAR_ENFORCE=off
# disables the gate entirely.

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
# shellcheck source=/dev/null
source "${ROOT}/lib/fingerprint.sh"

[[ "${DAR_ENFORCE:-advise}" == "off" ]] && exit 0

input="$(cat 2>/dev/null || true)"
active="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).stop_hook_active||false))}catch{process.stdout.write("false")}' 2>/dev/null || echo false)"

emit_block() {
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$1" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))' 2>/dev/null || printf '"%s"' "$1")"
  exit 0
}
# Unmeasurable state can't be cleared by a receipt → block once (advisory), not forever.
emit_block_once() { [[ "$active" == "true" ]] && exit 0; emit_block "$1"; }

# No changes → nothing to review.
[[ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]] || exit 0

# A ship-verdict review already ran for THIS exact working state → release.
# Guarded: if the helper didn't load, skip (fail-secure — treat as not reviewed).
declare -F dar_receipt_matches >/dev/null 2>&1 && dar_receipt_matches "$PROJ" && exit 0

REVIEW="Before finishing, run:  dar ripple --repo . --diff-base HEAD  — address any findings, then finish. (This gate clears only once dar ripple has reviewed the current diff and returned a SHIP verdict. For a deeper manual pass you can also use /codex:adversarial-review, but dar ripple is what records the review.)"
MEASURE_FAIL="dual-agent-review: this turn changed files but the blast radius could not be measured (node/probe unavailable). Failing secure — review the change for ripple/regression/fail-secure issues before finishing (dar ripple --repo . --diff-base HEAD, or /codex:adversarial-review)."

command -v node >/dev/null 2>&1 || emit_block_once "$MEASURE_FAIL"
# shellcheck source=/dev/null
[[ -f "$ROOT/config/defaults.sh" ]] && source "$ROOT/config/defaults.sh"

res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --diff-base HEAD 2>/dev/null)" || emit_block_once "$MEASURE_FAIL"
read -r survey fanout spread < <(
  printf '%s' "$res" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.survey} ${d.signals.fanout??"?"} ${d.signals.spread??"?"}`)}catch{process.stdout.write("PARSEFAIL ? ?")}'
)
[[ "$survey" == "PARSEFAIL" ]] && emit_block_once "$MEASURE_FAIL"
# Measured and contained → let Claude finish silently.
[[ "$survey" != "true" ]] && exit 0

# ── High blast radius. Decide with an ESCALATION LADDER, not an unconditional block. ──
# A naïve "always block until ship" ignores Claude Code's stop_hook_active flag and its
# ~8-consecutive-block override cap: it would loop and then get FORCE-OVERRIDDEN, letting
# an unshipped change finish while looking reviewed. Instead we bound our own blocking
# (well under CC's cap), honor stop_hook_active, and — rather than silently bypassing —
# ESCALATE loudly to the human and record an auditable blocked-unresolved marker.
MAX_BLOCKS="${DAR_MAX_STOP_BLOCKS:-4}"
verdict=""; blocks=0
if declare -F dar_receipt_verdict >/dev/null 2>&1; then
  verdict="$(dar_receipt_verdict "$PROJ" 2>/dev/null || true)"
fi

# A review ran for this exact diff but did NOT ship (block/revise). Distinguish that
# from "no review yet" so the message is honest about what happened.
if [[ -n "$verdict" && "$verdict" != "ship" ]]; then
  HEADER="dual-agent-review: the Codex review of THIS diff returned '${verdict}', not 'ship'. Address the findings (that changes the diff and triggers a fresh review), or explain why they are acceptable."
else
  HEADER="dual-agent-review: HIGH blast radius (fan-out ${fanout} files across ${spread} subsystems) and no shipping Codex review has run for this change yet."
fi

# Bounded, cap-aware escalation. Count blocks for this exact fingerprint.
if declare -F dar_bump_block_count >/dev/null 2>&1; then
  blocks="$(dar_bump_block_count "$PROJ" 2>/dev/null || echo 1)"
fi
if [[ "$blocks" -ge "$MAX_BLOCKS" ]]; then
  # Past our cap on the SAME unshipped diff: record the state and, on the next Stop
  # (stop_hook_active), stop re-blocking so we surface it to the human rather than
  # ceding control to CC's silent override. Never clears as reviewed-clean.
  declare -F dar_mark_blocked_unresolved >/dev/null 2>&1 && dar_mark_blocked_unresolved "$PROJ"
  if [[ "$active" == "true" ]]; then
    echo "dual-agent-review ⚠ FINISHING WITHOUT A PASSING REVIEW: ${HEADER} Blocked ${blocks}× with no resolution; recorded as blocked-unresolved. Re-run 'dar ripple --repo . --diff-base HEAD' after addressing the findings." >&2
    exit 0
  fi
  emit_block "⚠ ${HEADER} This change has been blocked ${blocks} times without a shipping review. ${REVIEW}"
fi
emit_block "${HEADER} ${REVIEW}"
