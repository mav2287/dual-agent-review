#!/usr/bin/env bash
# SessionStart bootstrap — run by the plugin's SessionStart(startup) hook. It runs
# each startup, but a marker file makes the one heavier step happen once per user.
#
# It keeps the `dar` CLI on the session PATH and best-effort installs the Codex
# plugin. It does NOT touch graphify: the probe uses graphify's graph only if one is
# already present and current, otherwise the in-house native graph — graphify stays
# fully opt-in via `dar setup`, and nothing is built inside your repos automatically.
# It never blocks a session; failures degrade quietly.

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/plugins/data/dual-agent-review}"
mkdir -p "$DATA"

# 1) Make `dar` available to Bash tool calls for the rest of this session.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo "export PATH=\"${ROOT}/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# 2) Install and leverage the official Codex plugin — once, best-effort. Hooks can't
#    run slash commands, but the `claude` CLI can add a marketplace and install a
#    plugin. This gives the manual /codex:adversarial-review surface the Stop gate
#    routes to. Tolerates absence/failure — the automatic review still works via
#    `dar ripple` if the plugin isn't present.
CODEX_PLUGIN_DONE="${DATA}/.codex-plugin-installed"
if [[ ! -f "$CODEX_PLUGIN_DONE" ]] && command -v claude >/dev/null 2>&1; then
  claude plugin marketplace add openai/codex-plugin-cc >/dev/null 2>&1 || true
  claude plugin install codex@openai-codex >/dev/null 2>&1 || true
  touch "$CODEX_PLUGIN_DONE"
fi

echo "dual-agent-review: active. High-blast changes are blocked at completion with instructions to run the Codex check (/codex:adversarial-review or dar ripple). The /dar-* slash commands are optional." >&2
exit 0
