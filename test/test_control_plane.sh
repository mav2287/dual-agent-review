#!/usr/bin/env bash
# Control-plane files (agent config + hook entrypoints) must never false-skip.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# Load the hot-path defaults the same way the real gates do.
# shellcheck source=/dev/null
source "$DAR_ROOT/config/defaults.sh"
echo "control planes never false-skip"

R="$(new_repo)"; trap 'rm -rf "$R"' EXIT
mkdir -p "$R/prompts" "$R/skills/x" "$R/commands" "$R/.claude" "$R/.codex" "$R/hooks" "$R/hook_scripts" "$R/docs"
echo "role prompt"        > "$R/prompts/review.md"
echo "skill"             > "$R/skills/x/SKILL.md"
echo "cmd"               > "$R/commands/do.md"
echo '{}'                > "$R/.claude/settings.json"
echo 'model="x"'         > "$R/.codex/config.toml"
echo "CLAUDE instr"      > "$R/CLAUDE.md"
echo "plain doc"         > "$R/docs/guide.md"
echo "readme"            > "$R/README.md"
# A hook whose entrypoint script lives OUTSIDE any hot-path dir — only hook-target
# detection (a real config→script edge) can catch it.
cat > "$R/hooks/hooks.json" <<'JSON'
{ "hooks": { "Stop": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "bash", "args": ["${CLAUDE_PLUGIN_ROOT}/hook_scripts/gate.sh"] } ] } ] } }
JSON
echo '#!/usr/bin/env bash' > "$R/hook_scripts/gate.sh"
git_commit "$R" init

for f in prompts/review.md skills/x/SKILL.md commands/do.md .claude/settings.json .codex/config.toml CLAUDE.md; do
  assert_eq "control plane surveys: $f" "true" "$(probe_field "$f" "$R" survey)"
done
# Hook entrypoint outside a hot-path dir → caught by hook-target detection.
assert_eq "hook entrypoint script surveys" "true" "$(probe_field hook_scripts/gate.sh "$R" survey)"
assert_contains "reason names it a hook entrypoint" "$(probe_field hook_scripts/gate.sh "$R" reasons)" "hook-entrypoint"

# Genuinely inert docs stay contained (we did not over-survey everything).
assert_eq "plain doc contained" "false" "$(probe_field docs/guide.md "$R" survey)"
assert_eq "README contained" "false" "$(probe_field README.md "$R" survey)"

finish
