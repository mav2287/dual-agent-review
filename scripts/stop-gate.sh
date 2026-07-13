#!/usr/bin/env bash
# Stop hook — the automatic engine. After Claude responds, it HARD-VERIFIES that an
# actual `dar ripple` review ran for the current high-blast state before letting
# Claude finish. It does NOT self-satisfy: it releases only when a review RECEIPT
# (written by dar ripple, keyed to the exact state fingerprint) matches, with a
# `ship` verdict. Fixing findings changes the fingerprint and forces a fresh review.
#
# SESSION SCOPING: the gate judges the SESSION'S OWN WORK, not whatever the worktree
# already carried. A SessionStart baseline (lib/baseline.mjs) defines the frame; the
# gate measures the session DELTA — including commits made during the session, so
# committing cannot launder a change past the gate. Pre-existing dirty/untracked
# files are inert. With no baseline (plugin activated mid-session) it falls back to
# gating the whole working state — conservative, never fail-open.
#
# Fail-secure: changes present but unmeasurable (node/probe/baseline failure) →
# block (advisory, once per turn, since no receipt can clear an unmeasurable state).
# DAR_ENFORCE=off disables the gate entirely.

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
# shellcheck source=/dev/null
source "${ROOT}/lib/fingerprint.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/trust.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/thresholds.sh"

[[ "${DAR_ENFORCE:-advise}" == "off" ]] && exit 0

input="$(cat 2>/dev/null || true)"
active="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).stop_hook_active||false))}catch{process.stdout.write("false")}' 2>/dev/null || echo false)"
sid="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).session_id||""))}catch{process.stdout.write("")}' 2>/dev/null || echo "")"

json_str() { printf '%s' "$1" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))' 2>/dev/null || printf '"%s"' "$1"; }
emit_block() {
  printf '{"decision":"block","reason":%s}\n' "$(json_str "$1")"
  exit 0
}
# Unmeasurable state can't be cleared by a receipt → block once per turn (a hard
# block would deadlock: nothing the model does can produce a receipt for a state we
# can't fingerprint). But the pass-through is NEVER silent: it records an auditable
# blocked-unresolved marker and surfaces a user-visible warning.
emit_block_once() {
  if [[ "$active" == "true" ]]; then
    declare -F dar_mark_blocked_unresolved_fp >/dev/null 2>&1 && dar_mark_blocked_unresolved_fp "$PROJ" "unmeasurable"
    echo "dual-agent-review ⚠ FINISHING WITH AN UNMEASURABLE CHANGE STATE (no review ran): $1" >&2
    printf '{"systemMessage":%s}\n' "$(json_str "⚠ dual-agent-review: this turn finished with an UNMEASURABLE change state — no review ran. Recorded as blocked-unresolved. $1")"
    exit 0
  fi
  emit_block "$1"
}

# Thresholds + hot-paths for the probe; then a trusted repo's .dar.thresholds.
# shellcheck source=/dev/null
[[ -f "$ROOT/config/defaults.sh" ]] && source "$ROOT/config/defaults.sh"
declare -F dar_load_thresholds >/dev/null 2>&1 && dar_load_thresholds "$PROJ"

DARBIN="${ROOT}/bin/dar"   # absolute — `dar` may not be on PATH mid-session
MEASURE_FAIL="dual-agent-review: this turn changed files but the blast radius could not be measured (node/probe/baseline unavailable). Failing secure — review the change for ripple/regression/fail-secure issues before finishing (\"${DARBIN}\" ripple --repo . , or /codex:adversarial-review)."

# ── determine mode + the state fingerprint ────────────────────────────────────
BF=""; MODE="legacy"
if [[ -n "$sid" ]] && command -v node >/dev/null 2>&1; then
  _bf="$(dar_baseline_path "$PROJ" "$sid")"
  [[ -f "$_bf" ]] && { BF="$_bf"; MODE="session"; }
fi

FILES_CSV=""   # session delta for the probe ("" → probe the full dirty state)
if [[ "$MODE" == "session" ]]; then
  deltaj="$(node "$ROOT/lib/baseline.mjs" delta --repo "$PROJ" --baseline "$BF" 2>/dev/null || true)"
  read -r d_ok d_count d_unsafe < <(
    printf '%s' "$deltaj" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.ok} ${d.ok?d.delta.length:0} ${d.ok?(d.unsafe||false):false}`)}catch{process.stdout.write("false 0 false")}'
  )
  [[ "$d_ok" != "true" ]] && emit_block_once "$MEASURE_FAIL"
  # Nothing changed this session (pre-existing worktree noise is inert) → finish.
  [[ "$d_count" -eq 0 ]] && exit 0
  if [[ "$d_count" -gt "${DAR_MAX_DELTA_FILES:-500}" ]]; then
    emit_block_once "dual-agent-review: this session's change-set is ${d_count} files (> DAR_MAX_DELTA_FILES=${DAR_MAX_DELTA_FILES:-500}) — too large to measure reliably; failing secure. If this is expected (branch switch, large rebase, generated output), re-frame the session with \"${DARBIN}\" baseline --repo . and continue; otherwise review before finishing (\"${DARBIN}\" ripple --repo . --baseline \"${BF}\")."
  fi
  # Comma/newline in a delta filename can't ride --files safely → full probe instead
  # (over-measures, never under-measures).
  [[ "$d_unsafe" != "true" ]] && FILES_CSV="$(printf '%s' "$deltaj" | node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(0)).delta.join(","))}catch{}' 2>/dev/null || true)"
  FP="$(dar_session_fingerprint "$PROJ" "$BF")"
  [[ -z "$FP" ]] && emit_block_once "$MEASURE_FAIL"
  REVIEW="Before finishing, run:  \"${DARBIN}\" ripple --repo . --baseline \"${BF}\"  — address any findings, then finish. (This gate clears only once dar ripple has reviewed this session's changes and returned a SHIP verdict. For a deeper manual pass you can also use /codex:adversarial-review, but dar ripple is what records the review.)"
else
  # Legacy: no baseline. No changes at all → nothing to review.
  [[ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]] || exit 0
  command -v node >/dev/null 2>&1 || emit_block_once "$MEASURE_FAIL"
  FP="$(dar_diff_fingerprint "$PROJ")"
  [[ -z "$FP" ]] && emit_block_once "$MEASURE_FAIL"
  REVIEW="Before finishing, run:  \"${DARBIN}\" ripple --repo . --diff-base HEAD  — address any findings, then finish. (This gate clears only once dar ripple has reviewed the current diff and returned a SHIP verdict. For a deeper manual pass you can also use /codex:adversarial-review, but dar ripple is what records the review.)"
fi

# A ship-verdict review already ran for THIS exact state → release.
dar_receipt_matches_fp "$PROJ" "$FP" && exit 0

# ── measure ───────────────────────────────────────────────────────────────────
if [[ -n "$FILES_CSV" ]]; then
  res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --files "$FILES_CSV" 2>/dev/null)" || emit_block_once "$MEASURE_FAIL"
else
  res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --diff-base HEAD 2>/dev/null)" || emit_block_once "$MEASURE_FAIL"
fi
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
verdict="$(dar_receipt_verdict_fp "$PROJ" "$FP" 2>/dev/null || true)"
# An EXPLICIT non-ship verdict (the reviewer looked and said no) holds the line
# longer than "no review yet" — still bounded below Claude Code's ~8-consecutive
# force-override so the escalation stays ours, loud and recorded, not CC's silent one.
[[ -n "$verdict" && "$verdict" != "ship" ]] && MAX_BLOCKS="${DAR_MAX_STOP_BLOCKS_NONSHIP:-6}"

# A review ran for this exact state but did NOT ship (block/revise). Distinguish that
# from "no review yet" so the message is honest about what happened.
if [[ -n "$verdict" && "$verdict" != "ship" ]]; then
  HEADER="dual-agent-review: the Codex review of THIS change returned '${verdict}', not 'ship'. Address the findings (that changes the state and triggers a fresh review), or explain why they are acceptable."
else
  HEADER="dual-agent-review: HIGH blast radius (fan-out ${fanout} files across ${spread} subsystems) and no shipping Codex review has run for this change yet."
fi

# Bounded, cap-aware escalation. Count blocks for this exact fingerprint.
blocks="$(dar_bump_block_count_fp "$PROJ" "$FP" 2>/dev/null || echo 1)"
if [[ "$blocks" -ge "$MAX_BLOCKS" ]]; then
  # Past our cap on the SAME unshipped state: record it and, on the next Stop
  # (stop_hook_active), stop re-blocking so we surface it to the human rather than
  # ceding control to CC's silent override. Never clears as reviewed-clean.
  dar_mark_blocked_unresolved_fp "$PROJ" "$FP"
  if [[ "$active" == "true" ]]; then
    echo "dual-agent-review ⚠ FINISHING WITHOUT A PASSING REVIEW: ${HEADER} Blocked ${blocks}× with no resolution; recorded as blocked-unresolved. Re-run the review after addressing the findings." >&2
    printf '{"systemMessage":%s}\n' "$(json_str "⚠ dual-agent-review: FINISHED WITHOUT A PASSING REVIEW after ${blocks} blocks — recorded as blocked-unresolved. ${HEADER}")"
    exit 0
  fi
  emit_block "⚠ ${HEADER} This change has been blocked ${blocks} times without a shipping review. ${REVIEW}"
fi
emit_block "${HEADER} ${REVIEW}"
