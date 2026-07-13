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

# create a >200KB tracked change
node -e 'process.stdout.write("x".repeat(400000)+"\n")' > "$R/big.txt"
git_commit "$R" big
node -e 'process.stdout.write("y".repeat(400000)+"\n")' > "$R/big.txt"   # ~400KB working diff

rc=0
DAR_CODEX_BIN="$STUB" bash "$DAR_ROOT/scripts/ripple.sh" --repo "$R" --diff-base HEAD >/dev/null 2>&1 || rc=$?
assert_true "large diff: reviewer ran, no SIGPIPE (rc≠141)" test "$rc" -ne 141
assert_eq "large diff: ship verdict → exit 0" "0" "$rc"

# truncation marker present in the built context
ctx="$(cat "$DAR_RUNS_DIR"/*-ripple-*/context.md 2>/dev/null | head -c 250000)"
assert_contains "diff truncation surfaced in context" "$ctx" "diff truncated"

# ship verdict was recorded in the receipt
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"
assert_eq "ship verdict recorded" "ship" "$(dar_receipt_verdict "$R")"

rm -f "$STUB"
finish
