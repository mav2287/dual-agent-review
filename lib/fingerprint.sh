# shellcheck shell=bash
# dual-agent-review — diff fingerprint + review receipt.
#
# The Stop gate hard-verifies that an actual `dar ripple` review ran for the CURRENT
# working state. Both sides must agree on what "the current state" is, so they compute
# one fingerprint here. It covers the tracked diff vs HEAD AND untracked file CONTENTS
# (not just their names) — a change to an untracked file must invalidate the receipt.

# dar_state_dir — where receipts live (plugin data dir, or a stable fallback).
dar_state_dir() { echo "${CLAUDE_PLUGIN_DATA:-${HOME}/.claude/plugins/data/dual-agent-review}"; }

# dar_projkey REPO — stable per-repo key.
dar_projkey() { printf '%s' "$1" | shasum 2>/dev/null | cut -c1-12; }

# dar_receipt_path REPO — the receipt file for REPO.
dar_receipt_path() { echo "$(dar_state_dir)/receipt-$(dar_projkey "$1")"; }

# dar_diff_fingerprint REPO — 40-hex fingerprint of the current working state.
dar_diff_fingerprint() {
  local repo="$1"
  {
    git -C "$repo" diff HEAD 2>/dev/null
    git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
      printf '== %s\n' "$f"
      cat "$repo/$f" 2>/dev/null
    done
  } | shasum 2>/dev/null | cut -c1-40
}

# dar_write_receipt REPO — record that a review completed for the current state.
dar_write_receipt() {
  local repo="$1" dir; dir="$(dar_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  dar_diff_fingerprint "$repo" > "$(dar_receipt_path "$repo")" 2>/dev/null || true
}

# dar_receipt_matches REPO — 0 if a receipt exists for the current state, else 1.
dar_receipt_matches() {
  local repo="$1" want have
  want="$(dar_diff_fingerprint "$repo")"
  [ -n "$want" ] || return 1
  have="$(cat "$(dar_receipt_path "$repo")" 2>/dev/null)"
  [ "$want" = "$have" ]
}
