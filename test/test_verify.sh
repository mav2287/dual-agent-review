#!/usr/bin/env bash
# L17 — dar verify runs the repo's configured deterministic gates.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "dar verify (L17)"

export DAR_STATE_DIR; DAR_STATE_DIR="$(mktemp -d)"
R="$(new_repo)"; trap 'rm -rf "$R" "$DAR_STATE_DIR"' EXIT

# Unconfigured → NOT success (the merge authority must not green with no gates).
rc=0; out="$(bash "$DAR_ROOT/scripts/verify.sh" --repo "$R" 2>&1)" || rc=$?
assert_eq "unconfigured → non-success (exit 3)" "3" "$rc"
assert_contains "unconfigured → guidance" "$out" ".dar.config.sh"
# ...unless explicitly opted in.
rc=0; bash "$DAR_ROOT/scripts/verify.sh" --repo "$R" --allow-unconfigured >/dev/null 2>&1 || rc=$?
assert_eq "unconfigured + --allow-unconfigured → exit 0" "0" "$rc"

# The gates live in .dar.config.sh, which only executes for TRUSTED repos — an
# untrusted fixture must stay unconfigured even with the file present.
printf 'export DAR_TYPECHECK_CMD="true"\n' > "$R/.dar.config.sh"
rc=0; bash "$DAR_ROOT/scripts/verify.sh" --repo "$R" >/dev/null 2>&1 || rc=$?
assert_eq "untrusted repo config unseen → non-success" "3" "$rc"
bash "$DAR_ROOT/bin/dar" trust --repo "$R" >/dev/null

# All gates pass → exit 0.
printf 'export DAR_TYPECHECK_CMD="true"\nexport DAR_TEST_CMD="true"\n' > "$R/.dar.config.sh"
rc=0; bash "$DAR_ROOT/scripts/verify.sh" --repo "$R" >/dev/null 2>&1 || rc=$?
assert_eq "all gates pass → exit 0" "0" "$rc"

# A failing gate → exit 1.
printf 'export DAR_TYPECHECK_CMD="true"\nexport DAR_TEST_CMD="false"\n' > "$R/.dar.config.sh"
rc=0; bash "$DAR_ROOT/scripts/verify.sh" --repo "$R" >/dev/null 2>&1 || rc=$?
assert_eq "failing gate → exit 1" "1" "$rc"

# DAR_NO_REPO_CONFIG=1 must not source the repo config → gates unseen → non-success.
rc=0; DAR_NO_REPO_CONFIG=1 bash "$DAR_ROOT/scripts/verify.sh" --repo "$R" >/dev/null 2>&1 || rc=$?
assert_eq "no-repo-config → non-success (gates unseen)" "3" "$rc"

finish
