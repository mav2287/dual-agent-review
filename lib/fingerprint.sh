# shellcheck shell=bash
# dual-agent-review — diff fingerprint + review receipt.
#
# The Stop gate hard-verifies that an actual `dar ripple` review ran for the CURRENT
# working state. Both sides must agree on what "the current state" is, so they compute
# one fingerprint. Two modes share the receipt machinery below:
#
#   • session mode — a SessionStart baseline exists: the fingerprint is computed by
#     lib/baseline.mjs over the SESSION DELTA (tracked diff vs the baseline HEAD +
#     session-new/changed untracked contents). Pre-existing worktree noise is inert,
#     and committing mid-session does NOT clear the state (the diff vs baseline HEAD
#     still covers it).
#   • legacy mode — no baseline (plugin activated mid-session, hook missed): the
#     fingerprint covers the whole working state — tracked diff vs HEAD AND every
#     untracked file's CONTENT. Conservative and noisy, but never fail-open.
#
# All receipt/count helpers take the fingerprint EXPLICITLY (_fp suffix) so the two
# modes share one implementation; the legacy-named wrappers compute the legacy
# fingerprint themselves and remain for callers/tests that predate session mode.

# dar_state_dir — where receipts/baselines/counters live. DELIBERATELY NOT
# CLAUDE_PLUGIN_DATA: hooks get that injected per-plugin, but a CLI invocation from
# the Bash tool inherits whatever leaked into the session env — observed live: the
# codex plugin's bootstrap exported ITS data dir, dar ripple wrote receipts there,
# and the Stop hook (reading dar's injected dir) never saw three SHIP verdicts. One
# stable dar-owned path on both sides; DAR_STATE_DIR overrides for tests.
dar_state_dir() { echo "${DAR_STATE_DIR:-${HOME}/.claude/plugins/data/dual-agent-review}"; }

# dar_projkey REPO — stable per-repo key. Canonicalized to the PHYSICAL path at
# this single choke point: every state file (receipt, baseline, block counter,
# marker) derives its name here, and the same repo reaches different gates under
# different aliases — CLAUDE_PROJECT_DIR may say /var/... while a `cd . && pwd`
# says /private/var/... (macOS), which silently keyed ripple's receipt under a
# different hash than the Stop gate looked up (observed live: three SHIP verdicts,
# gate never released). An unresolvable path falls back to the raw string.
dar_projkey() {
  local p
  p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"
  printf '%s' "$p" | shasum 2>/dev/null | cut -c1-12
}

# dar_receipt_path REPO — the receipt file for REPO.
dar_receipt_path() { echo "$(dar_state_dir)/receipt-$(dar_projkey "$1")"; }

# dar_block_count_path REPO / dar_blocked_marker_path REPO — Stop-gate escalation state.
dar_block_count_path() { echo "$(dar_state_dir)/blocks-$(dar_projkey "$1")"; }
dar_blocked_marker_path() { echo "$(dar_state_dir)/blocked-unresolved-$(dar_projkey "$1")"; }

# dar_baseline_path REPO SESSION_ID — the SessionStart baseline manifest for REPO in
# one session. The id is sanitized to a filename-safe charset.
dar_baseline_path() {
  local sid="${2:-}"
  sid="${sid//[^a-zA-Z0-9_-]/}"
  echo "$(dar_state_dir)/baseline-$(dar_projkey "$1")-${sid:-none}"
}

# dar_diff_fingerprint REPO — 40-hex LEGACY fingerprint of the whole working state.
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

# dar_session_fingerprint REPO BASELINE_FILE — 40-hex SESSION fingerprint. Empty on
# any failure — callers MUST treat empty as unmeasurable (block), never as clean.
dar_session_fingerprint() {
  local repo="$1" bf="$2" home
  home="${DAR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  [ -f "$bf" ] || return 0
  node "${home}/lib/baseline.mjs" fingerprint --repo "$repo" --baseline "$bf" 2>/dev/null || true
}

# ── receipt (fingerprint-explicit core + legacy wrappers) ──────────────────────

# dar_write_receipt_fp REPO FP VERDICT — record that a review with VERDICT completed
# for the state FP. The verdict is stored WITH the fingerprint so the Stop gate can
# release only on `ship` (#7); a non-ship review leaves a matching receipt that does
# NOT clear.
dar_write_receipt_fp() {
  local repo="$1" fp="$2" verdict="${3:-unknown}" dir; dir="$(dar_state_dir)"
  [ -n "$fp" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$fp" "$verdict" > "$(dar_receipt_path "$repo")" 2>/dev/null || true
}
dar_write_receipt() { dar_write_receipt_fp "$1" "$(dar_diff_fingerprint "$1")" "${2:-unknown}"; }

# dar_receipt_verdict_fp REPO FP — echo the stored verdict iff it was recorded for
# exactly FP, else empty (a receipt for a different/older state does not count).
dar_receipt_verdict_fp() {
  local repo="$1" want="$2" line have_fp
  [ -n "$want" ] || return 0
  line="$(cat "$(dar_receipt_path "$repo")" 2>/dev/null)" || return 0
  have_fp="${line%% *}"
  [ "$want" = "$have_fp" ] && printf '%s' "${line#* }"
}
dar_receipt_verdict() { dar_receipt_verdict_fp "$1" "$(dar_diff_fingerprint "$1")"; }

# dar_receipt_matches_fp REPO FP — 0 ONLY if a receipt exists for FP AND its verdict
# is `ship`. A block/revise review does not release the gate.
dar_receipt_matches_fp() { [ "$(dar_receipt_verdict_fp "$1" "$2")" = "ship" ]; }
dar_receipt_matches() { dar_receipt_matches_fp "$1" "$(dar_diff_fingerprint "$1")"; }

# ── Stop-gate escalation state (fingerprint-explicit core + legacy wrappers) ───

# dar_block_count_fp REPO FP — how many times the Stop gate has already blocked THIS
# exact unshipped state (0 if the stored fingerprint differs, i.e. the state changed).
dar_block_count_fp() {
  local repo="$1" want="$2" line fp
  [ -n "$want" ] || { echo 0; return 0; }
  line="$(cat "$(dar_block_count_path "$repo")" 2>/dev/null)" || { echo 0; return 0; }
  fp="${line%% *}"
  if [ "$fp" = "$want" ]; then echo "${line#* }"; else echo 0; fi
}
dar_block_count() { dar_block_count_fp "$1" "$(dar_diff_fingerprint "$1")"; }

# dar_bump_block_count_fp REPO FP — increment (resetting when the fingerprint
# changed) and echo the new count.
dar_bump_block_count_fp() {
  local repo="$1" want="$2" n dir; dir="$(dar_state_dir)"
  [ -n "$want" ] || { echo 0; return 0; }
  n=$(( $(dar_block_count_fp "$repo" "$want") + 1 ))
  mkdir -p "$dir" 2>/dev/null || { echo "$n"; return 0; }
  printf '%s %s\n' "$want" "$n" > "$(dar_block_count_path "$repo")" 2>/dev/null || true
  echo "$n"
}
dar_bump_block_count() { dar_bump_block_count_fp "$1" "$(dar_diff_fingerprint "$1")"; }

# dar_mark_blocked_unresolved_fp REPO FP — persist an auditable marker that this
# exact state escalated past the block cap without a ship verdict (never mistaken
# for clean).
dar_mark_blocked_unresolved_fp() {
  local repo="$1" fp="$2" dir; dir="$(dar_state_dir)"
  [ -n "$fp" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s blocked-unresolved\n' "$fp" > "$(dar_blocked_marker_path "$repo")" 2>/dev/null || true
}
dar_mark_blocked_unresolved() { dar_mark_blocked_unresolved_fp "$1" "$(dar_diff_fingerprint "$1")"; }
