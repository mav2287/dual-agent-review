#!/usr/bin/env bash
# Hook-entrypoint discovery — control scripts registered in hooks config must force a
# survey, INCLUDING when the hook uses a shell-form command string ("bash ./x.sh")
# whose script path is a token inside the string, not the whole string.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "hook-entrypoint discovery (shell-form)"

R="$(new_repo)"; trap 'rm -rf "$R"' EXIT
mkdir -p "$R/.claude" "$R/hooks"
echo 'echo lint' > "$R/hooks/lint-on-edit.sh"
cat > "$R/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit|Write",
        "hooks": [ { "type": "command", "command": "bash ./hooks/lint-on-edit.sh --fast" } ] }
    ]
  }
}
JSON
git_commit "$R" init
echo 'echo lint v2' > "$R/hooks/lint-on-edit.sh"

survey="$(probe_field "hooks/lint-on-edit.sh" "$R" "survey")"
reasons="$(probe_field "hooks/lint-on-edit.sh" "$R" "reasons")"
assert_eq "shell-form hook script → survey" "true" "$survey"
assert_contains "reason names the hook entrypoint" "$reasons" "hook-entrypoint"

# Exec form (command + args array) keeps working.
cat > "$R/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash", "args": ["./hooks/lint-on-edit.sh"] } ] }
    ]
  }
}
JSON
reasons="$(probe_field "hooks/lint-on-edit.sh" "$R" "reasons")"
assert_contains "exec-form hook script still detected" "$reasons" "hook-entrypoint"

finish
