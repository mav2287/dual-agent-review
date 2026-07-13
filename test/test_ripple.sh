#!/usr/bin/env bash
# B5 — ripple diff handling: no SIGPIPE abort on large diffs, truncation surfaced, and
# fail-secure on an invalid --diff-base (never review an empty diff as clean).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "ripple diff handling (B5)"

export CLAUDE_PLUGIN_DATA; CLAUDE_PLUGIN_DATA="$(mktemp -d)"
export DAR_RUNS_DIR; DAR_RUNS_DIR="$(mktemp -d)/runs"

R="$(new_repo)"; trap 'rm -rf "$R" "$CLAUDE_PLUGIN_DATA"' EXIT
echo "seed" > "$R/seed.txt"; git_commit "$R" init

# 1) Invalid --diff-base must fail secure (exit 2), before any review.
rc=0; bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --diff-base does-not-exist-ref >/dev/null 2>&1 || rc=$?
assert_eq "invalid --diff-base → fail-secure exit 2" "2" "$rc"

# 2) A >200 KB diff must truncate, run the (stubbed) reviewer, and NOT abort with 141.
STUB="$(mktemp)"; cat > "$STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"verdict":"ship","summary":"stub","findings":[],"scope_conformance":{"respected_scope_map":true,"out_of_frame_touches":[]},"coverage":{"reviewed":"all","not_reviewed":"none"}}
JSON
SH
chmod +x "$STUB"

# create a tracked change larger than the diff cap (default 600 KB)
node -e 'process.stdout.write("x".repeat(900000)+"\n")' > "$R/big.txt"
git_commit "$R" big
node -e 'process.stdout.write("y".repeat(900000)+"\n")' > "$R/big.txt"   # ~900KB working diff

rc=0
DAR_CODEX_BIN="$STUB" bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --diff-base HEAD >/dev/null 2>&1 || rc=$?
assert_true "large diff: reviewer ran, no SIGPIPE (rc≠141)" test "$rc" -ne 141
# A ship verdict over a TRUNCATED context must NOT ship: the receipt would cover
# content the reviewer never saw. Downgraded to 'partial' (non-release), exit 3.
assert_eq "truncated context: ship downgraded (exit 3)" "3" "$rc"

# truncation marker present in the built context
ctx="$(cat "$DAR_RUNS_DIR"/*-ripple-*/context.md 2>/dev/null | head -c 650000)"
assert_contains "diff truncation surfaced in context" "$ctx" "diff truncated"

# the receipt records 'partial', which never clears the Stop gate
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"
assert_eq "partial verdict recorded" "partial" "$(dar_receipt_verdict "$R")"

# an UNtruncated review with the same stub ships normally (exit 0, ship receipt)
git -C "$R" checkout -q -- big.txt
echo small-change > "$R/seed.txt"
rc=0; DAR_CODEX_BIN="$STUB" bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --diff-base HEAD >/dev/null 2>&1 || rc=$?
assert_eq "untruncated review ships (exit 0)" "0" "$rc"
assert_eq "ship verdict recorded" "ship" "$(dar_receipt_verdict "$R")"

# 3) Legacy mode: untracked contents ARE in the review context — the receipt
#    fingerprint covers them, so the reviewer must see them.
echo 'export function sneaky(){return true}' > "$R/sneaky-impl.js"
out="$(DAR_CODEX_BIN="$STUB" bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --diff-base HEAD 2>/dev/null || true)"
rundir="$(printf '%s' "$out" | sed -n 's/.*(findings: \(.*\)\/review\.json)$/\1/p' | tail -1)"
ctx="$(cat "$rundir/context.md")"
assert_contains "untracked file named in context" "$ctx" "sneaky-impl.js"
assert_contains "untracked file CONTENT in context" "$ctx" "function sneaky"

# 4) Session mode: same guarantee via the baseline's untrackedDelta, and the receipt
#    is keyed to the SESSION fingerprint (which the Stop gate verifies).
BF="$(dar_baseline_path "$R" ripS)"
git -C "$R" checkout -q -- . 2>/dev/null || true
rm -f "$R/sneaky-impl.js"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R" --out "$BF" >/dev/null
echo 'export function sessionImpl(){return 1}' > "$R/session-impl.js"
rc=0; out="$(DAR_CODEX_BIN="$STUB" bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --baseline "$BF" 2>/dev/null)" || rc=$?
assert_eq "session ripple with stub → exit 0" "0" "$rc"
rundir="$(printf '%s' "$out" | sed -n 's/.*(findings: \(.*\)\/review\.json)$/\1/p' | tail -1)"
ctx="$(cat "$rundir/context.md")"
assert_contains "session untracked content in context" "$ctx" "function sessionImpl"
FP="$(DAR_HOME="$DAR_ROOT" dar_session_fingerprint "$R" "$BF")"
assert_eq "session receipt keyed to session fingerprint" "ship" "$(dar_receipt_verdict_fp "$R" "$FP")"

# 5) --baseline and --diff-base together are contradictory → usage error.
rc=0; bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --baseline "$BF" --diff-base HEAD >/dev/null 2>&1 || rc=$?
assert_eq "baseline + diff-base rejected" "2" "$rc"

# 6) Symlink trust boundary: an untracked symlink's TARGET content must never enter
#    the review context or run artifacts — only the link target path is disclosed.
SECRET="$(mktemp)"; echo "TOPSECRET-HOST-VALUE" > "$SECRET"
ln -s "$SECRET" "$R/leak-link"
out="$(DAR_CODEX_BIN="$STUB" bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --diff-base HEAD 2>/dev/null || true)"
rundir="$(printf '%s' "$out" | sed -n 's/.*(findings: \(.*\)\/review\.json)$/\1/p' | tail -1)"
ctx="$(cat "$rundir/context.md")"
assert_contains "symlink is named in context" "$ctx" "leak-link"
assert_contains "symlink reported as symlink" "$ctx" "symlink"
assert_not_contains "symlink target content NOT disclosed" "$ctx" "TOPSECRET-HOST-VALUE"
rm -f "$SECRET" "$R/leak-link"

rm -f "$STUB"
finish
