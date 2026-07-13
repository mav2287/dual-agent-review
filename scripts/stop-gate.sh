#!/usr/bin/env bash
# Stop hook — the automatic engine. After Claude responds, it checks whether the
# session made a high-blast change with no shipping `dar ripple` review recorded.
#
# ENFORCEMENT (DAR_ENFORCE): the DEFAULT is `advise` — a DIRECTIVE, not a trap. On
# unreviewed high-blast work it injects ONE visible, recorded reminder to run the
# review and lets Claude finish. It never blocks, so an imperfect measurement (a
# missing baseline, a parallel lane's files, an unmeasurable state) can only
# over-REMIND, never trap the agent or pressure it toward laundering. `block` is the
# opt-in hard gate: it refuses completion until a receipt (written by dar ripple,
# keyed to the exact state fingerprint) matches with a `ship` verdict. `off` disables
# the hook entirely.
#
# Why advise-by-default: dar's own thesis is that DETERMINISTIC gates (tests/lint/
# typecheck, via `dar verify`) are the merge authority and the LLM review is a
# high-value SIGNAL — never itself a merge gate. Hard-blocking completion on an LLM
# verdict inverts that, and every scoping edge case becomes a hard trap. Advise keeps
# the signal loud without the trap; block is there when you trust the scoping and
# want the guarantee.
#
# SESSION SCOPING (both modes): the gate judges the SESSION'S OWN WORK, not whatever
# the worktree already carried. A SessionStart baseline (lib/baseline.mjs) defines the
# frame; the gate measures the session DELTA — including commits made during the
# session. Pre-existing dirty/untracked files are inert. With no baseline (e.g. the
# plugin was activated mid-session via /reload-plugins, which fires no SessionStart)
# it falls back to the whole working tree — which is exactly why the DEFAULT only
# advises: an unscoped fallback must not trap.

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
# shellcheck source=/dev/null
source "${ROOT}/lib/fingerprint.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/trust.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/thresholds.sh"

MODE="${DAR_ENFORCE:-advise}"   # off | advise (default) | block
[[ "$MODE" == "off" ]] && exit 0

input="$(cat 2>/dev/null || true)"
active="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).stop_hook_active||false))}catch{process.stdout.write("false")}' 2>/dev/null || echo false)"
sid="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).session_id||""))}catch{process.stdout.write("")}' 2>/dev/null || echo "")"

json_str() { printf '%s' "$1" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))' 2>/dev/null || printf '"%s"' "$1"; }

# emit_advise MSG — DEFAULT path: never blocks. One visible + recorded reminder, then
# let Claude finish. Advisory reminders are once-per-turn (stop_hook_active) so a
# multi-step turn isn't nagged repeatedly.
emit_advise() {
  [[ "$active" == "true" ]] && exit 0
  echo "dual-agent-review ⓘ (advisory) $1" >&2
  printf '{"systemMessage":%s}\n' "$(json_str "ⓘ dual-agent-review — advisory (set DAR_ENFORCE=block to hard-gate): $1")"
  exit 0
}

# emit_block MSG — block-mode only: refuse completion.
emit_block() {
  printf '{"decision":"block","reason":%s}\n' "$(json_str "$1")"
  exit 0
}

# emit_unmeasurable MSG — a changed-but-unmeasurable state (node/probe/baseline down).
# advise: remind (non-blocking). block: block once per turn (a hard block would
# deadlock — nothing the model does can produce a receipt for a state we can't
# fingerprint), recording an auditable marker so the pass-through is never silent.
emit_unmeasurable() {
  [[ "$MODE" != "block" ]] && emit_advise "$1"
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
MEASURE_FAIL="dual-agent-review: this turn changed files but the blast radius could not be measured (node/probe/baseline unavailable). Review the change for ripple/regression/fail-secure issues before finishing (\"${DARBIN}\" ripple --repo . , or /codex:adversarial-review)."

# ── determine mode + the state fingerprint ────────────────────────────────────
BF=""; SCOPE="legacy"
if [[ -n "$sid" ]] && command -v node >/dev/null 2>&1; then
  _bf="$(dar_baseline_path "$PROJ" "$sid")"
  [[ -f "$_bf" ]] && { BF="$_bf"; SCOPE="session"; }
fi

FILES_CSV=""   # session delta for the probe ("" → probe by diff base)
PROBE_BASE="HEAD"
if [[ "$SCOPE" == "session" ]]; then
  deltaj="$(node "$ROOT/lib/baseline.mjs" delta --repo "$PROJ" --baseline "$BF" 2>/dev/null || true)"
  read -r d_ok d_count d_unsafe d_head < <(
    printf '%s' "$deltaj" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.ok} ${d.ok?d.delta.length:0} ${d.ok?(d.unsafe||false):false} ${d.baseHead||"?"}`)}catch{process.stdout.write("false 0 false ?")}'
  )
  [[ "$d_ok" != "true" ]] && emit_unmeasurable "$MEASURE_FAIL"
  # If we can't ride --files (comma/newline filenames), the fallback probe must diff
  # against the BASELINE head — a HEAD-based probe sees a clean tree once the change
  # is committed, which would let exactly those filenames bypass the review.
  if [[ "$d_head" == "NONE" ]]; then
    PROBE_BASE="$(git -C "$PROJ" hash-object -t tree /dev/null 2>/dev/null)" || PROBE_BASE=""
    [[ -n "$PROBE_BASE" ]] || emit_unmeasurable "$MEASURE_FAIL"
  elif [[ "$d_head" != "?" ]]; then
    PROBE_BASE="$d_head"
  else
    emit_unmeasurable "$MEASURE_FAIL"
  fi
  # Nothing changed this session (pre-existing worktree noise is inert) → finish.
  [[ "$d_count" -eq 0 ]] && exit 0
  if [[ "$d_count" -gt "${DAR_MAX_DELTA_FILES:-500}" ]]; then
    emit_unmeasurable "this session's change-set is ${d_count} files (> DAR_MAX_DELTA_FILES=${DAR_MAX_DELTA_FILES:-500}) — too large to measure reliably. If expected (branch switch, large rebase, generated output), re-frame with \"${DARBIN}\" baseline --repo . ; otherwise review before finishing (\"${DARBIN}\" ripple --repo . --baseline \"${BF}\")."
  fi
  # Comma/newline in a delta filename can't ride --files safely → full probe instead
  # (over-measures, never under-measures).
  [[ "$d_unsafe" != "true" ]] && FILES_CSV="$(printf '%s' "$deltaj" | node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(0)).delta.join(","))}catch{}' 2>/dev/null || true)"
  FP="$(dar_session_fingerprint "$PROJ" "$BF")"
  [[ -z "$FP" ]] && emit_unmeasurable "$MEASURE_FAIL"
  REVIEW="Run:  \"${DARBIN}\" ripple --repo . --baseline \"${BF}\"  to review this session's changes. (In block mode this gate clears only on a SHIP verdict for the current state; a deeper manual pass is /codex:adversarial-review.)"
else
  # Legacy: no baseline (e.g. /reload-plugins gave hooks but no SessionStart). No
  # changes at all → nothing to review. NB: legacy can't isolate the session's work
  # from pre-existing / parallel-lane files, which is precisely why the default only
  # advises here — see the header.
  [[ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]] || exit 0
  command -v node >/dev/null 2>&1 || emit_unmeasurable "$MEASURE_FAIL"
  FP="$(dar_diff_fingerprint "$PROJ")"
  [[ -z "$FP" ]] && emit_unmeasurable "$MEASURE_FAIL"
  REVIEW="Run:  \"${DARBIN}\" ripple --repo . --diff-base HEAD  to review the current diff. (In block mode this gate clears only on a SHIP verdict; a deeper manual pass is /codex:adversarial-review.) Note: without a session baseline this measures the WHOLE working tree, so it may include pre-existing or parallel-lane files."
fi

# A ship-verdict review already ran for THIS exact state → nothing to do, either mode.
dar_receipt_matches_fp "$PROJ" "$FP" && exit 0

# ── measure ───────────────────────────────────────────────────────────────────
if [[ -n "$FILES_CSV" ]]; then
  res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --files "$FILES_CSV" 2>/dev/null)" || emit_unmeasurable "$MEASURE_FAIL"
else
  res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --diff-base "$PROBE_BASE" 2>/dev/null)" || emit_unmeasurable "$MEASURE_FAIL"
fi
read -r survey fanout spread < <(
  printf '%s' "$res" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.survey} ${d.signals.fanout??"?"} ${d.signals.spread??"?"}`)}catch{process.stdout.write("PARSEFAIL ? ?")}'
)
[[ "$survey" == "PARSEFAIL" ]] && emit_unmeasurable "$MEASURE_FAIL"
# Measured and contained → let Claude finish silently (both modes).
[[ "$survey" != "true" ]] && exit 0

# ── High blast radius, no shipping review. ────────────────────────────────────
verdict="$(dar_receipt_verdict_fp "$PROJ" "$FP" 2>/dev/null || true)"
if [[ -n "$verdict" && "$verdict" != "ship" ]]; then
  HEADER="dual-agent-review: the Codex review of THIS change returned '${verdict}', not 'ship'. Address the findings (that changes the state and triggers a fresh review), or explain why they are acceptable."
else
  HEADER="dual-agent-review: HIGH blast radius (fan-out ${fanout} files across ${spread} subsystems) and no shipping Codex review has run for this change yet."
fi

# DEFAULT (advise): one non-blocking reminder, then finish.
[[ "$MODE" != "block" ]] && emit_advise "${HEADER} ${REVIEW}"

# ── block mode: bounded, cap-aware escalation (never an unconditional loop). ──
# A naïve "always block until ship" ignores Claude Code's stop_hook_active flag and its
# ~8-consecutive-block override cap: it would loop and then get FORCE-OVERRIDDEN, letting
# an unshipped change finish while looking reviewed. Instead we bound our own blocking
# (well under CC's cap), honor stop_hook_active, and — rather than silently bypassing —
# ESCALATE loudly to the human and record an auditable blocked-unresolved marker.
MAX_BLOCKS="${DAR_MAX_STOP_BLOCKS:-4}"
# An EXPLICIT non-ship verdict (the reviewer looked and said no) holds the line longer
# than "no review yet" — still bounded below CC's ~8-consecutive force-override.
[[ -n "$verdict" && "$verdict" != "ship" ]] && MAX_BLOCKS="${DAR_MAX_STOP_BLOCKS_NONSHIP:-6}"

blocks="$(dar_bump_block_count_fp "$PROJ" "$FP" 2>/dev/null || echo 1)"
if [[ "$blocks" -ge "$MAX_BLOCKS" ]]; then
  dar_mark_blocked_unresolved_fp "$PROJ" "$FP"
  if [[ "$active" == "true" ]]; then
    echo "dual-agent-review ⚠ FINISHING WITHOUT A PASSING REVIEW: ${HEADER} Blocked ${blocks}× with no resolution; recorded as blocked-unresolved. Re-run the review after addressing the findings." >&2
    printf '{"systemMessage":%s}\n' "$(json_str "⚠ dual-agent-review: FINISHED WITHOUT A PASSING REVIEW after ${blocks} blocks — recorded as blocked-unresolved. ${HEADER}")"
    exit 0
  fi
  emit_block "⚠ ${HEADER} This change has been blocked ${blocks} times without a shipping review. ${REVIEW}"
fi
emit_block "${HEADER} ${REVIEW}"
