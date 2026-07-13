#!/usr/bin/env bash
# B7 — Stop gate: ship-only release + bounded, cap-aware escalation (no silent bypass).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "stop gate escalation (B7)"

export CLAUDE_PLUGIN_DATA; CLAUDE_PLUGIN_DATA="$(mktemp -d)"
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"

R="$(new_repo)"; trap 'rm -rf "$R" "$CLAUDE_PLUGIN_DATA"' EXIT
echo '{"v":1}' > "$R/config.json"; git_commit "$R" init
echo '{"v":2}' > "$R/config.json"   # working change to an opaque control file → survey=true

# run_stop ACTIVE [MAX] → writes stdout to $OUT_F and stderr to $ERR_F (avoids losing
# state through a command-substitution subshell).
OUT_F="$(mktemp)"; ERR_F="$(mktemp)"
run_stop() {
  printf '{"stop_hook_active":%s}' "$1" \
    | CLAUDE_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_MAX_STOP_BLOCKS="${2:-4}" \
      bash "$DAR_ROOT/scripts/stop-gate.sh" >"$OUT_F" 2>"$ERR_F"
}
OUT() { cat "$OUT_F"; }
ERR() { cat "$ERR_F"; }

# 1) No receipt for a high-blast change → block.
run_stop false
assert_contains "no receipt → block" "$(OUT)" '"decision":"block"'

# 2) A block-verdict receipt for this exact diff → still blocks, and says so.
dar_write_receipt "$R" "block"
run_stop false
assert_contains "block receipt still blocks" "$(OUT)" '"decision":"block"'
assert_contains "message names the non-ship verdict" "$(OUT)" "block"

# 3) A ship receipt for this exact diff → releases (no block emitted).
dar_write_receipt "$R" "ship"
run_stop false
assert_not_contains "ship receipt releases (no block)" "$(OUT)" '"decision":"block"'

# 4) Escalation: same unshipped diff blocked past the cap, then stop_hook_active=true
#    → stop looping, escalate loudly to stderr, exit 0, and record the marker.
CLAUDE_PLUGIN_DATA="$(mktemp -d)"          # fresh counter state
dar_write_receipt "$R" "block"
run_stop false 2                           # block #1 (<2)
run_stop false 2                           # block #2 (== cap)
assert_contains "at cap still blocks (active=false)" "$(OUT)" '"decision":"block"'
run_stop true 2                            # over cap, active → escalate, don't loop
assert_not_contains "over cap + active → no block (escalates)" "$(OUT)" '"decision":"block"'
assert_contains "escalation warns the human on stderr" "$(ERR)" "WITHOUT A PASSING REVIEW"
assert_true "blocked-unresolved marker recorded" test -f "$(dar_blocked_marker_path "$R")"

finish
