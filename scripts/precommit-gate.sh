#!/usr/bin/env bash
# PreToolUse gate on `git commit` — the plugin's default "behavior change".
#
# Runs ONLY the fast, deterministic blast-radius probe (no Codex, ~1s). When a
# high-blast change is about to be committed, it surfaces a notice so the change
# doesn't slip past the review loop. FAIL-SECURE: if it cannot measure (node
# missing, probe error), it advises rather than staying silent — the whole point
# is that uncertainty must not read as "clear".
#
# Modes (env DAR_ENFORCE):
#   advise (default) — print a notice, let the commit proceed (exit 1)
#   block            — refuse the commit until reviewed (exit 2)
#   off              — silent (exit 0)

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
MODE="${DAR_ENFORCE:-advise}"

[[ "$MODE" == "off" ]] && exit 0

emit() { # MESSAGE
  echo "$1" >&2
  [[ "$MODE" == "block" ]] && exit 2 || exit 1
}

# Load thresholds + the hot-path list (exported) so the probe actually applies
# them — without this the tripwire is empty and hot files look "contained".
# shellcheck source=/dev/null
[ -f "$ROOT/config/defaults.sh" ] && source "$ROOT/config/defaults.sh"
# NOTE: this hook fires automatically on EVERY commit, in any repo — so it must
# NOT execute the target repo's `.dar.config.sh` (arbitrary shell). It uses the
# built-in generic defaults only. Per-repo tuning applies in the manual review
# gates, which you run deliberately on a repo you trust.

# Can't measure without node → don't stay silent; advise.
command -v node >/dev/null 2>&1 || emit "dual-agent-review: node not found, cannot measure blast radius — review this change manually before committing."

# The probe builds its own graph (graphify not required). Fail-secure on any error.
res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --diff-base HEAD 2>/dev/null)" \
  || emit "dual-agent-review: blast-radius probe failed — review this change manually before committing."

read -r survey fanout spread < <(
  printf '%s' "$res" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.survey} ${d.signals.fanout??"?"} ${d.signals.spread??"?"}`)}catch{process.stdout.write("true ? ?")}'
)

# survey=false → genuinely contained → allow silently.
[[ "$survey" == "false" ]] && exit 0

emit "dual-agent-review ⚠ HIGH blast radius: fan-out ${fanout} across ${spread} subsystems. Run the Codex check before committing — /codex:adversarial-review or 'dar ripple --repo . --diff-base HEAD'. Set DAR_ENFORCE=off to silence, =block to enforce."
