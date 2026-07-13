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

# dar_block_count_path REPO / dar_blocked_marker_path REPO — Stop-gate escalation state.
dar_block_count_path() { echo "$(dar_state_dir)/blocks-$(dar_projkey "$1")"; }
dar_blocked_marker_path() { echo "$(dar_state_dir)/blocked-unresolved-$(dar_projkey "$1")"; }

# dar_diff_fingerprint REPO — 40-hex fingerprint of the current working state.
# Covers the tracked diff vs HEAD AND untracked file CONTENTS. Untracked names are read
# NUL-delimited (`ls-files -z`) so newline/quote/tab filenames don't break enumeration
# (#8), and every field is LENGTH- and NUL-framed so two distinct file sets can't
# collide onto the same pre-hash byte stream (e.g. `== a\nX== b\nY` was ambiguous).
dar_diff_fingerprint() {
  local repo="$1"
  {
    printf 'DIFF\0'
    git -C "$repo" diff HEAD 2>/dev/null; printf '\0'
    git -C "$repo" ls-files -z --others --exclude-standard 2>/dev/null | while IFS= read -r -d '' f; do
      local path="$repo/$f" clen
      clen=$(wc -c < "$path" 2>/dev/null | tr -d ' '); [ -n "$clen" ] || clen=0
      # LENGTH-framed header + NUL-terminated name + NUL-terminated content: no two
      # distinct (name, content) sets can produce the same pre-hash byte stream.
      printf 'F namelen=%s bytes=%s\0' "${#f}" "$clen"
      printf '%s\0' "$f"
      cat "$path" 2>/dev/null; printf '\0'
    done
  } | shasum 2>/dev/null | cut -c1-40
}

# dar_write_receipt REPO VERDICT — record that a review with VERDICT completed for the
# current state. The verdict is stored WITH the fingerprint so the Stop gate can release
# only on `ship` (#7); a non-ship review leaves a matching receipt that does NOT clear.
dar_write_receipt() {
  local repo="$1" verdict="${2:-unknown}" dir; dir="$(dar_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$(dar_diff_fingerprint "$repo")" "$verdict" > "$(dar_receipt_path "$repo")" 2>/dev/null || true
}

# dar_receipt_verdict REPO — echo the stored verdict for the CURRENT fingerprint, else
# empty (a receipt for a different/older diff does not count).
dar_receipt_verdict() {
  local repo="$1" want line have_fp
  want="$(dar_diff_fingerprint "$repo")"; [ -n "$want" ] || return 0
  line="$(cat "$(dar_receipt_path "$repo")" 2>/dev/null)" || return 0
  have_fp="${line%% *}"
  [ "$want" = "$have_fp" ] && printf '%s' "${line#* }"
}

# dar_receipt_matches REPO — 0 ONLY if a receipt exists for the current state AND its
# verdict is `ship`. A block/revise review does not release the gate.
dar_receipt_matches() {
  local repo="$1" v
  v="$(dar_receipt_verdict "$repo")"
  [ "$v" = "ship" ]
}

# dar_block_count REPO — how many times the Stop gate has already blocked THIS exact
# unshipped diff (0 if the stored fingerprint differs, i.e. the diff changed).
dar_block_count() {
  local repo="$1" want line fp
  want="$(dar_diff_fingerprint "$repo")"; [ -n "$want" ] || { echo 0; return 0; }
  line="$(cat "$(dar_block_count_path "$repo")" 2>/dev/null)" || { echo 0; return 0; }
  fp="${line%% *}"
  if [ "$fp" = "$want" ]; then echo "${line#* }"; else echo 0; fi
}

# dar_bump_block_count REPO — increment (resetting when the fingerprint changed) and
# echo the new count.
dar_bump_block_count() {
  local repo="$1" want n dir; dir="$(dar_state_dir)"
  want="$(dar_diff_fingerprint "$repo")"; [ -n "$want" ] || { echo 0; return 0; }
  n=$(( $(dar_block_count "$repo") + 1 ))
  mkdir -p "$dir" 2>/dev/null || { echo "$n"; return 0; }
  printf '%s %s\n' "$want" "$n" > "$(dar_block_count_path "$repo")" 2>/dev/null || true
  echo "$n"
}

# dar_mark_blocked_unresolved REPO — persist an auditable marker that this exact diff
# escalated past the block cap without a ship verdict (never mistaken for clean).
dar_mark_blocked_unresolved() {
  local repo="$1" dir; dir="$(dar_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s blocked-unresolved\n' "$(dar_diff_fingerprint "$repo")" > "$(dar_blocked_marker_path "$repo")" 2>/dev/null || true
}
