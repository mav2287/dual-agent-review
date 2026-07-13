#!/usr/bin/env bash
# Session-baseline scoping — the Stop gate judges the session's own work: pre-existing
# worktree noise is inert, committing mid-session cannot launder a change, a SHIP
# receipt keyed to the session fingerprint releases, and a too-large delta fails
# secure (block-once) instead of being silently skipped.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "session baseline (stop gate scoping)"

export DAR_STATE_DIR; DAR_STATE_DIR="$(mktemp -d)"
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"

R="$(new_repo)"; trap 'rm -rf "$R" "$DAR_STATE_DIR"' EXIT
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
    | env "$@" CLAUDE_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_STATE_DIR="$DAR_STATE_DIR" \
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
rm -f "$DAR_STATE_DIR"/receipt-* "$DAR_STATE_DIR"/blocks-*
run_stop false DAR_MAX_DELTA_FILES=0
assert_contains "oversized delta blocks" "$(OUT)" '"decision":"block"'
assert_contains "oversized delta names the escape hatch" "$(OUT)" 'baseline --repo .'
run_stop true DAR_MAX_DELTA_FILES=0
assert_not_contains "oversized delta blocks only once per turn" "$(OUT)" '"decision":"block"'

# 7) `dar baseline` re-frames: after re-capture the same worktree state is inert —
#    and the use is RECORDED (deliberate escape hatches must be auditable).
bash "$DAR_ROOT/bin/dar" baseline --repo "$R" >/dev/null
run_stop
assert_not_contains "re-baseline makes current state inert" "$(OUT)" '"decision":"block"'
assert_true "re-baseline recorded in the audit log" \
  test -n "$(cat "$DAR_STATE_DIR"/rebaseline-log-* 2>/dev/null)"
echo new-work > "$R/after-rebase.json"
run_stop
assert_contains "work after re-baseline gates again" "$(OUT)" '"decision":"block"'

# 8) A corrupt baseline is unmeasurable → block-once; the same-turn pass-through is
#    LOUD (systemMessage + blocked-unresolved marker), never silent-clean.
echo garbage > "$BF"
run_stop
assert_contains "corrupt baseline fails secure" "$(OUT)" '"decision":"block"'
rm -f "$(dar_blocked_marker_path "$R")"
run_stop true
assert_not_contains "unmeasurable + active does not deadlock" "$(OUT)" '"decision":"block"'
assert_contains "unmeasurable pass-through is user-visible" "$(OUT)" 'systemMessage'
assert_true "unmeasurable pass-through recorded as blocked-unresolved" test -f "$(dar_blocked_marker_path "$R")"

# 9) delta subcommand: committed range + changed files enumerated, junk excluded.
BF2="$(dar_baseline_path "$R" sessB)"
git -C "$R" checkout -q -- . 2>/dev/null || true
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R" --out "$BF2" >/dev/null
echo delta-work > "$R/dwork.txt"
d="$(node "$DAR_ROOT/lib/baseline.mjs" delta --repo "$R" --baseline "$BF2")"
assert_contains "delta lists session file" "$d" 'dwork.txt'
assert_not_contains "delta excludes pre-existing junk" "$d" 'junk/a.txt'

# 10) Content proof, not mtime: a same-size content swap with the mtime restored to
#     the baseline's must STILL land in the delta (unchanged = size AND hash).
printf 'AAAA' > "$R/junk/swap.txt"
BF3="$(dar_baseline_path "$R" sessC)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R" --out "$BF3" >/dev/null
cp -p "$R/junk/swap.txt" "$R/junk/swap.ref"     # keep a same-mtime reference
printf 'BBBB' > "$R/junk/swap.txt"              # same size, new content
touch -r "$R/junk/swap.ref" "$R/junk/swap.txt"  # restore the baseline mtime
d="$(node "$DAR_ROOT/lib/baseline.mjs" delta --repo "$R" --baseline "$BF3")"
assert_contains "same-size same-mtime content swap is detected" "$d" 'junk/swap.txt'

# 11) A baseline captured BEFORE the first commit still fingerprints tracked content
#     created by a mid-session initial commit (empty-tree diff base).
R2="$(mktemp -d)"
git -C "$R2" init -q; git -C "$R2" config user.email t@t; git -C "$R2" config user.name t; git -C "$R2" config commit.gpgsign false
BFE="$(dar_baseline_path "$R2" sessE)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R2" --out "$BFE" >/dev/null
echo v1 > "$R2/app.js"; git_commit "$R2" first
fp1="$(node "$DAR_ROOT/lib/baseline.mjs" fingerprint --repo "$R2" --baseline "$BFE")"
echo v2 > "$R2/app.js"; git_commit "$R2" second
fp2="$(node "$DAR_ROOT/lib/baseline.mjs" fingerprint --repo "$R2" --baseline "$BFE")"
assert_true "pre-first-commit baseline: tracked edits move the fingerprint" test "$fp1" != "$fp2"
rm -rf "$R2"

# 12) A COMMITTED session change whose filename contains a comma (can't ride
#     --files) must still gate: the fallback probe diffs against the BASELINE head,
#     not HEAD (which would see a clean tree after the commit).
R4="$(new_repo)"
echo base > "$R4/a.txt"; git_commit "$R4" init
BF4="$(dar_baseline_path "$R4" sessU)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R4" --out "$BF4" >/dev/null
echo '{"v":1}' > "$R4/we,ird.json"          # opaque control file, comma name
git_commit "$R4" "commit the unsafe-named session change"
out="$(printf '{"stop_hook_active":false,"session_id":"sessU"}' \
  | CLAUDE_PROJECT_DIR="$R4" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_STATE_DIR="$DAR_STATE_DIR" \
    bash "$DAR_ROOT/scripts/stop-gate.sh" 2>/dev/null)"
assert_contains "committed comma-named change still blocks" "$out" '"decision":"block"'
rm -rf "$R4"

# 13) Deleting a PRE-EXISTING untracked file is a session change: it enters the
#     delta and moves the fingerprint (a stale receipt must not survive it).
R5="$(new_repo)"
echo base > "$R5/a.txt"; git_commit "$R5" init
echo cfg > "$R5/local-config.json"
BF5="$(dar_baseline_path "$R5" sessD)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R5" --out "$BF5" >/dev/null
fpA="$(node "$DAR_ROOT/lib/baseline.mjs" fingerprint --repo "$R5" --baseline "$BF5")"
rm "$R5/local-config.json"
d="$(node "$DAR_ROOT/lib/baseline.mjs" delta --repo "$R5" --baseline "$BF5")"
assert_contains "deleted untracked file is in the delta" "$d" 'local-config.json'
assert_contains "deletion reported as deletion" "$d" 'deletedUntracked'
fpB="$(node "$DAR_ROOT/lib/baseline.mjs" fingerprint --repo "$R5" --baseline "$BF5")"
assert_true "deletion moves the fingerprint" test "$fpA" != "$fpB"
out="$(printf '{"stop_hook_active":false,"session_id":"sessD"}' \
  | CLAUDE_PROJECT_DIR="$R5" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_STATE_DIR="$DAR_STATE_DIR" \
    bash "$DAR_ROOT/scripts/stop-gate.sh" 2>/dev/null)"
assert_contains "deletion gates at Stop" "$out" '"decision":"block"'
rm -rf "$R5"

# 14) Symlinks are hashed by TARGET PATH, never read through: editing the target's
#     content must NOT change the fingerprint (no host-file state leaks into it).
R6="$(new_repo)"
echo base > "$R6/a.txt"; git_commit "$R6" init
TGT="$(mktemp)"; echo one > "$TGT"
BF6="$(dar_baseline_path "$R6" sessL)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R6" --out "$BF6" >/dev/null
ln -s "$TGT" "$R6/cfg-link"
fpL1="$(node "$DAR_ROOT/lib/baseline.mjs" fingerprint --repo "$R6" --baseline "$BF6")"
echo two > "$TGT"     # mutate the TARGET, not the link
fpL2="$(node "$DAR_ROOT/lib/baseline.mjs" fingerprint --repo "$R6" --baseline "$BF6")"
assert_eq "target edits do not move the fingerprint (no read-through)" "$fpL1" "$fpL2"
rm -rf "$R6" "$TGT"

# 14b) State keys are alias-proof: the same repo reached via a symlinked path must
#      key to the SAME state files (receipt written by ripple under one alias must
#      be found by the Stop gate under another — /var vs /private/var on macOS).
RA="$(new_repo)"
LNKD="$(mktemp -d)"; ln -s "$RA" "$LNKD/alias"
assert_eq "projkey identical across path aliases" "$(dar_projkey "$RA")" "$(dar_projkey "$LNKD/alias")"
dar_write_receipt_fp "$LNKD/alias" "feedfacefeedfacefeedfacefeedfacefeedface" ship
assert_true "receipt written via alias is found via real path" \
  dar_receipt_matches_fp "$RA" "feedfacefeedfacefeedfacefeedfacefeedface"
rm -rf "$RA" "$LNKD"

# 15) A session whose only change is a NEW positively-inert file (a scratch note)
#     passes silently — while a new CODE file still gates (no consumers visible ≠
#     no consumers).
R7="$(new_repo)"
echo base > "$R7/a.txt"; git_commit "$R7" init
BF7="$(dar_baseline_path "$R7" sessN)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R7" --out "$BF7" >/dev/null
echo "remember the milk" > "$R7/notes.txt"
out="$(printf '{"stop_hook_active":false,"session_id":"sessN"}' \
  | CLAUDE_PROJECT_DIR="$R7" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_STATE_DIR="$DAR_STATE_DIR" \
    bash "$DAR_ROOT/scripts/stop-gate.sh" 2>/dev/null)"
assert_not_contains "new inert note passes silently" "$out" '"decision":"block"'
echo 'module.exports = () => true' > "$R7/new-code.js"
out="$(printf '{"stop_hook_active":false,"session_id":"sessN"}' \
  | CLAUDE_PROJECT_DIR="$R7" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_STATE_DIR="$DAR_STATE_DIR" \
    bash "$DAR_ROOT/scripts/stop-gate.sh" 2>/dev/null)"
assert_contains "new code file still gates" "$out" '"decision":"block"'
rm -rf "$R7"

finish
