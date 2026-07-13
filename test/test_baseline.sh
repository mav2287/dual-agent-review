#!/usr/bin/env bash
# Session-baseline scoping — the Stop gate judges the session's own work: pre-existing
# worktree noise is inert, committing mid-session cannot launder a change, a SHIP
# receipt keyed to the session fingerprint releases, and a too-large delta fails
# secure (block-once) instead of being silently skipped.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "session baseline (stop gate scoping)"

export CLAUDE_PLUGIN_DATA; CLAUDE_PLUGIN_DATA="$(mktemp -d)"
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"

R="$(new_repo)"; trap 'rm -rf "$R" "$CLAUDE_PLUGIN_DATA"' EXIT
echo base > "$R/app.txt"; git_commit "$R" init

# Pre-existing noise the session did NOT create: untracked junk + a dirty tracked file.
mkdir -p "$R/junk"
echo n1 > "$R/junk/a.txt"; echo n2 > "$R/junk/b.txt"
echo tweak >> "$R/app.txt"

BF="$(dar_baseline_path "$R" sessA)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R" --out "$BF" >/dev/null
assert_true "baseline captured" test -f "$BF"

OUT_F="$(mktemp)"; ERR_F="$(mktemp)"
run_stop() { # [ACTIVE] [EXTRA_ENV as VAR=VAL ...]
  local active="${1:-false}"; shift 2>/dev/null || true
  printf '{"stop_hook_active":%s,"session_id":"sessA"}' "$active" \
    | env "$@" CLAUDE_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      bash "$DAR_ROOT/scripts/stop-gate.sh" >"$OUT_F" 2>"$ERR_F"
}
OUT() { cat "$OUT_F"; }

# 1) Pre-existing junk + dirty tracked file, NO session work → silent pass.
run_stop
assert_not_contains "pre-existing noise is inert (no block)" "$(OUT)" '"decision":"block"'

# 2) The session adds a control-plane file → survey → block, message routes to
#    dar ripple --baseline.
echo '{"x":1}' > "$R/settings.json"
run_stop
assert_contains "session hot file → block" "$(OUT)" '"decision":"block"'
assert_contains "block message hands out the baseline" "$(OUT)" '--baseline'

# 3) Committing the session work does NOT launder it (diff vs baseline HEAD).
git_commit "$R" "session work"
run_stop
assert_contains "commit-then-Stop still blocks" "$(OUT)" '"decision":"block"'

# 4) A SHIP receipt keyed to the SESSION fingerprint releases the gate.
FP="$(DAR_HOME="$DAR_ROOT" dar_session_fingerprint "$R" "$BF")"
assert_true "session fingerprint computed" test -n "$FP"
dar_write_receipt_fp "$R" "$FP" ship
run_stop
assert_not_contains "session ship receipt releases" "$(OUT)" '"decision":"block"'

# 5) Editing after the review invalidates the receipt → blocks again.
echo more >> "$R/settings.json"
run_stop
assert_contains "post-review edit re-blocks" "$(OUT)" '"decision":"block"'

# 6) Delta over DAR_MAX_DELTA_FILES → fail-secure block-once with a re-baseline hint.
rm -f "$CLAUDE_PLUGIN_DATA"/receipt-* "$CLAUDE_PLUGIN_DATA"/blocks-*
run_stop false DAR_MAX_DELTA_FILES=0
assert_contains "oversized delta blocks" "$(OUT)" '"decision":"block"'
assert_contains "oversized delta names the escape hatch" "$(OUT)" 'baseline --repo .'
run_stop true DAR_MAX_DELTA_FILES=0
assert_not_contains "oversized delta blocks only once per turn" "$(OUT)" '"decision":"block"'

# 7) `dar baseline` re-frames: after re-capture the same worktree state is inert.
bash "$DAR_ROOT/bin/dar" baseline --repo "$R" >/dev/null
run_stop
assert_not_contains "re-baseline makes current state inert" "$(OUT)" '"decision":"block"'
echo new-work > "$R/after-rebase.json"
run_stop
assert_contains "work after re-baseline gates again" "$(OUT)" '"decision":"block"'

# 8) A corrupt baseline is unmeasurable → block-once, never silent-clean.
echo garbage > "$BF"
run_stop
assert_contains "corrupt baseline fails secure" "$(OUT)" '"decision":"block"'

# 9) delta subcommand: committed range + changed files enumerated, junk excluded.
BF2="$(dar_baseline_path "$R" sessB)"
git -C "$R" checkout -q -- . 2>/dev/null || true
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R" --out "$BF2" >/dev/null
echo delta-work > "$R/dwork.txt"
d="$(node "$DAR_ROOT/lib/baseline.mjs" delta --repo "$R" --baseline "$BF2")"
assert_contains "delta lists session file" "$d" 'dwork.txt'
assert_not_contains "delta excludes pre-existing junk" "$d" 'junk/a.txt'

finish
