#!/usr/bin/env bash
# Stop hook — the AUTOMATIC engine. After Claude finishes responding, this runs
# the fast blast-radius probe on the working changes. On a high-blast change (or
# when the change can't be measured) it BLOCKS completion once and makes Claude run
# an adversarial review before finishing. No separate user prompt is needed — the
# hook tells Claude which review command to run.
#
# Fail-secure: changes present + unmeasurable → block (never silently allow).
# Non-nagging: blocks once per DISTINCT change-state (a diff hash), and honors
# stop_hook_active so it can't loop within a turn.
#
# Modes (env DAR_ENFORCE): advise (default) | off.

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"

[[ "${DAR_ENFORCE:-advise}" == "off" ]] && exit 0

input="$(cat 2>/dev/null || true)"
active="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).stop_hook_active||false))}catch{process.stdout.write("false")}' 2>/dev/null || echo false)"
[[ "$active" == "true" ]] && exit 0

# Any changes at all this turn? Cheap, no node. None → nothing to review.
have_changes() { [[ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]]; }
have_changes || exit 0

# A fingerprint of the current change-state (tracked diff + untracked list). We
# force a review at most once per distinct fingerprint, so the gate doesn't re-nag
# every turn while Claude keeps working on the same reviewed change.
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/plugins/data/dual-agent-review}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
projkey="$(printf '%s' "$PROJ" | shasum 2>/dev/null | cut -c1-12)"
STATE="${STATE_DIR}/reviewed-${projkey:-x}"
diffhash="$({ git -C "$PROJ" diff HEAD 2>/dev/null; git -C "$PROJ" status --porcelain 2>/dev/null; } | shasum 2>/dev/null | cut -c1-16)"
[[ -n "$diffhash" && "$(cat "$STATE" 2>/dev/null)" == "$diffhash" ]] && exit 0

# Block once for this change-state (record it first so we don't re-nag), JSON on stdout.
emit_block() {
  printf '%s' "$diffhash" > "$STATE" 2>/dev/null || true
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$1" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))' 2>/dev/null || printf '"%s"' "$1")"
  exit 0
}

MEASURE_FAIL="dual-agent-review: this turn changed files but the blast radius could not be measured (node or probe unavailable). Failing secure — review this change for ripple, regression, and fail-secure issues before finishing: run /codex:adversarial-review, or dar ripple --repo . --diff-base HEAD."

command -v node >/dev/null 2>&1 || emit_block "$MEASURE_FAIL"
# shellcheck source=/dev/null
[[ -f "$ROOT/config/defaults.sh" ]] && source "$ROOT/config/defaults.sh"

res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --diff-base HEAD 2>/dev/null)" || emit_block "$MEASURE_FAIL"
read -r survey fanout spread < <(
  printf '%s' "$res" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.survey} ${d.signals.fanout??"?"} ${d.signals.spread??"?"}`)}catch{process.stdout.write("PARSEFAIL ? ?")}'
)
[[ "$survey" == "PARSEFAIL" ]] && emit_block "$MEASURE_FAIL"
# Measured and contained → let Claude finish silently. The common case.
[[ "$survey" != "true" ]] && exit 0

emit_block "dual-agent-review: this change has HIGH blast radius (fan-out ${fanout} files across ${spread} subsystems). Before finishing, run an adversarial cross-model review and address any real findings: run /codex:adversarial-review, or dar ripple --repo . --diff-base HEAD. Have Codex check the consumers this change could break, the fail-secure / auth / tenant paths, and anything outside the intended frame. If it comes back clean, say so and finish."
