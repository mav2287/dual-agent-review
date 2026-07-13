#!/usr/bin/env bash
# B3 — precommit gate self-guard + advisory/block modes.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "precommit gate (B3)"

R="$(new_repo)"; trap 'rm -rf "$R"' EXIT
echo '{"v":1}' > "$R/config.json"; git_commit "$R" init
echo '{"v":2}' > "$R/config.json"   # opaque control-file change → high blast

run_pre() { # MODE COMMAND_JSON
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_ENFORCE="$1" \
    bash "$DAR_ROOT/scripts/precommit-gate.sh" >/dev/null 2>&1
}

# Self-guard: a non-commit Bash command is skipped regardless of blast radius.
rc=0; run_pre advise '{"tool_input":{"command":"git status"}}' || rc=$?
assert_eq "non-commit command → skip (exit 0)" "0" "$rc"

# A git-commit command (compound form) on a high-blast change → advisory (exit 1).
rc=0; run_pre advise '{"tool_input":{"command":"cd '"$R"' && git commit -m x"}}' || rc=$?
assert_eq "commit + high blast → advise (exit 1)" "1" "$rc"

# block mode → refuse (exit 2).
rc=0; run_pre block '{"tool_input":{"command":"git commit -m x"}}' || rc=$?
assert_eq "commit + high blast + block → exit 2" "2" "$rc"

# off mode → silent (exit 0).
rc=0; run_pre off '{"tool_input":{"command":"git commit -m x"}}' || rc=$?
assert_eq "off mode → exit 0" "0" "$rc"

finish
