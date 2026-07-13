#!/usr/bin/env bash
# SessionStart bootstrap — run by the plugin's SessionStart hook (startup, resume,
# and clear). It runs each time, but marker files keep the heavy steps one-shot.
#
# It (1) keeps the `dar` CLI reachable — session PATH via CLAUDE_ENV_FILE plus a
# stable ~/.local/bin symlink; (2) captures the SESSION BASELINE the Stop gate
# measures against (capture-if-absent: a resume keeps the original frame; a new
# session id gets a fresh one); (3) best-effort installs the Codex plugin. It does
# NOT touch graphify: the probe uses graphify's graph only if one is already present
# and current, otherwise the in-house native graph — graphify stays fully opt-in via
# `dar setup`, and nothing is built inside your repos automatically. It never blocks
# a session; failures degrade quietly (a missing baseline only means the Stop gate
# falls back to gating the whole working state — conservative, not fail-open).

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/plugins/data/dual-agent-review}"
mkdir -p "$DATA"

input="$(cat 2>/dev/null || true)"

# 1) Make `dar` available to Bash tool calls for the rest of this session, and via a
#    stable symlink for anything else (`/reload-plugins` does not re-run this hook,
#    so the symlink is what keeps `dar` reachable outside a fresh session).
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo "export PATH=\"${ROOT}/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
if [[ -d "${HOME}/.local/bin" ]] || mkdir -p "${HOME}/.local/bin" 2>/dev/null; then
  ln -sf "${ROOT}/bin/dar" "${HOME}/.local/bin/dar" 2>/dev/null || true
fi

# 2) Capture the session baseline for the Stop gate's session-delta scoping.
if command -v node >/dev/null 2>&1; then
  sid="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).session_id||""))}catch{process.stdout.write("")}' 2>/dev/null || echo "")"
  cwd="$(printf '%s' "$input" | node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(0)).cwd||""))}catch{process.stdout.write("")}' 2>/dev/null || echo "")"
  PROJ="${CLAUDE_PROJECT_DIR:-$cwd}"
  if [[ -n "$sid" && -n "$PROJ" ]] && git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${ROOT}/lib/fingerprint.sh"
    BF="$(dar_baseline_path "$PROJ" "$sid")"
    if [[ ! -f "$BF" ]]; then
      node "${ROOT}/lib/baseline.mjs" capture --repo "$PROJ" --out "$BF" >/dev/null 2>&1 || true
    fi
  fi
fi

# 3) Install and leverage the official Codex plugin — once, best-effort. Hooks can't
#    run slash commands, but the `claude` CLI can add a marketplace and install a
#    plugin. This gives the manual /codex:adversarial-review surface the Stop gate
#    mentions. Tolerates absence/failure — the automatic review runs via `dar ripple`
#    (the receipt-writing path) whether or not the plugin is present.
CODEX_PLUGIN_DONE="${DATA}/.codex-plugin-installed"
CODEX_PLUGIN_RETRY="${DATA}/.codex-plugin-retry"   # epoch of the last FAILED attempt
CODEX_RETRY_COOLDOWN="${DAR_CODEX_RETRY_COOLDOWN:-86400}"  # retry at most once/day on failure

# Independently verify the codex plugin is actually installed — a zero exit from
# `plugin install` is not proof (finding #13). Only the done-marker suppresses retries,
# and it is written ONLY after this verification succeeds.
codex_plugin_installed() {
  command -v claude >/dev/null 2>&1 || return 1
  claude plugin list 2>/dev/null | grep -qi 'codex'
}

if [[ ! -f "$CODEX_PLUGIN_DONE" ]] && command -v claude >/dev/null 2>&1; then
  if codex_plugin_installed; then
    touch "$CODEX_PLUGIN_DONE"                       # already present → stop trying
    rm -f "$CODEX_PLUGIN_RETRY" 2>/dev/null || true
  else
    now="$(date +%s 2>/dev/null || echo 0)"
    last="$(cat "$CODEX_PLUGIN_RETRY" 2>/dev/null || echo 0)"
    # Bounded COOLDOWN (not a permanent attempt cap): a transient failure is retried in
    # a later session once the cooldown elapses, so we never give up forever.
    if [[ $(( now - last )) -ge $CODEX_RETRY_COOLDOWN ]]; then
      claude plugin marketplace add openai/codex-plugin-cc >/dev/null 2>&1 || true
      claude plugin install codex@openai-codex >/dev/null 2>&1 || true
      if codex_plugin_installed; then
        touch "$CODEX_PLUGIN_DONE"                   # VERIFIED installed → done
        rm -f "$CODEX_PLUGIN_RETRY" 2>/dev/null || true
      else
        echo "$now" > "$CODEX_PLUGIN_RETRY" 2>/dev/null || true   # failed → cooldown, retry later
      fi
    fi
  fi
fi

echo "dual-agent-review: active. High-blast changes made THIS SESSION are blocked at completion until a 'dar ripple' review returns SHIP (pre-existing worktree noise is ignored). The /dar-* slash commands are optional." >&2
exit 0
