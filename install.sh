#!/usr/bin/env bash
# Install dual-agent-review.
#
#   ./install.sh                 global: `dar` onto PATH + skill/commands into ~/.claude
#   ./install.sh --repo <path>   install skill/commands into one project's .claude/
#   ./install.sh --bin-dir <d>   override where `dar` is symlinked (default ~/.local/bin)
#
# The toolkit itself stays in this directory; install only creates a `dar` symlink
# and drops the thin Claude Code invocation layer (skill + slash commands) where
# Claude Code looks for them. No target repo source is modified.

set -euo pipefail
DAR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="global"; REPO=""; BIN_DIR="${HOME}/.local/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) MODE="repo"; REPO="$2"; shift 2;;
    --bin-dir) BIN_DIR="$2"; shift 2;;
    *) echo "install: unknown arg $1" >&2; exit 2;;
  esac
done

link_commands_and_skill() { # DEST_CLAUDE_DIR
  local dest="$1"
  mkdir -p "${dest}/commands" "${dest}/skills/dual-agent-review"
  for f in "${DAR_HOME}"/commands/*.md; do
    ln -sf "$f" "${dest}/commands/$(basename "$f")"
  done
  ln -sf "${DAR_HOME}/skills/dual-agent-review/SKILL.md" "${dest}/skills/dual-agent-review/SKILL.md"
  echo "  ✓ skill + slash commands → ${dest}"
}

echo "dual-agent-review installer (${MODE})"

if [[ "$MODE" == "global" ]]; then
  mkdir -p "$BIN_DIR"
  ln -sf "${DAR_HOME}/bin/dar" "${BIN_DIR}/dar"
  echo "  ✓ dar → ${BIN_DIR}/dar"
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) echo "  ⚠ ${BIN_DIR} is not on PATH — add it to your shell profile";;
  esac
  link_commands_and_skill "${HOME}/.claude"
else
  [[ -n "$REPO" && -d "$REPO" ]] || { echo "install: --repo path not found" >&2; exit 2; }
  REPO="$(cd "$REPO" && pwd)"
  link_commands_and_skill "${REPO}/.claude"
  echo "  note: run \`dar\` via its full path or install globally too for the CLI."
fi

echo "done. verify with: dar doctor"
