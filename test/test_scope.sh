#!/usr/bin/env bash
# Pre-plan scope must NOT skip on a clean branch (no diff yet). An empty working tree is
# not proof the intended task is contained — it surveys the task instead.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "pre-plan scope (clean branch)"

export DAR_RUNS_DIR; DAR_RUNS_DIR="$(mktemp -d)/runs"
R="$(new_repo)"; trap 'rm -rf "$R"' EXIT
echo "seed" > "$R/seed.txt"; git_commit "$R" init   # committed → clean working tree, no diff

# Stub reviewer emits a valid-enough scope map so the survey path completes.
STUB="$(mktemp)"; cat > "$STUB" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"terrain":"stub","consumers":[],"invariants":[],"plan_constraints":["treat X as a requirement"],"coverage":{"reviewed":"all","not_reviewed":"none"}}
JSON
SH
chmod +x "$STUB"

rc=0
out="$(DAR_CODEX_BIN="$STUB" DAR_NO_REPO_CONFIG=1 bash "$DAR_ROOT/scripts/scope.sh" \
        --repo "$R" --task "add authentication to the login flow" 2>&1)" || rc=$?
assert_eq "clean-branch scope → exit 0" "0" "$rc"
assert_not_contains "clean branch does NOT skip" "$out" "SKIP"
assert_contains "clean branch surveys the task" "$out" "surveying"
assert_contains "explains pre-plan no-diff survey" "$out" "pre-plan"

# With --force it always surveys too (sanity).
rc=0
out="$(DAR_CODEX_BIN="$STUB" DAR_NO_REPO_CONFIG=1 bash "$DAR_ROOT/scripts/scope.sh" \
        --repo "$R" --task "t" --force 2>&1)" || rc=$?
assert_eq "forced scope → exit 0" "0" "$rc"

rm -f "$STUB"
finish
