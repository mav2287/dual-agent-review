#!/usr/bin/env bash
# UserPromptSubmit hook — a light, ONCE-PER-SESSION reminder to run the upstream
# gates on high-blast work. Advisory only (adds to context via stdout); never blocks.
# Once per session so it doesn't habituate. DAR_ENFORCE=off silences it.
#
# The upstream gates (scope survey, plan red-team) can't be hook-enforced — there's no
# "a plan was produced" event, especially for informal "put a plan together" requests
# — so this reminder plus the skill's standing trigger are how they get run.

set -uo pipefail

[[ "${DAR_ENFORCE:-advise}" == "off" ]] && exit 0

input="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).session_id||"x"))}catch{process.stdout.write("x")}' 2>/dev/null || echo x)"

DATA="${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/plugins/data/dual-agent-review}"
mkdir -p "$DATA" 2>/dev/null || true
marker="${DATA}/advised-${sid}"
[[ -f "$marker" ]] && exit 0
touch "$marker" 2>/dev/null || true

echo "dual-agent-review: for high-blast work (auth, migrations, shared modules, public interfaces, cross-subsystem changes), run 'dar scope' before planning and 'dar plan-redteam' on the plan before coding — for both formal plans and 'put a plan together' requests. Skip for contained/mechanical changes. The post-diff Codex review is enforced automatically."
exit 0
