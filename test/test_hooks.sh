#!/usr/bin/env bash
# B1 / B3 / N10 — manifest + hook schema. Strict plugin validation (when the CLI is
# present) plus structural checks on hooks.json (tool-name matcher, handler-level `if`,
# exec-form commands with args).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "manifest + hooks (B1/B3/N10)"

# B1: marketplace source is the string form.
src="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).plugins[0].source))' "$DAR_ROOT/.claude-plugin/marketplace.json")"
assert_eq "marketplace source is relative-path string" "./" "$src"

# hooks.json structural contract.
H="$DAR_ROOT/hooks/hooks.json"
assert_true "hooks.json is valid JSON" node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$H"

# Emit space-free tokens (the `if` value itself contains a space) so `read` splits cleanly.
read -r matcher ifok execform < <(node -e '
const h=JSON.parse(require("fs").readFileSync(process.argv[1]));
const pre=h.hooks.PreToolUse[0];
const handler=pre.hooks[0];
const ifok=typeof handler.if==="string" && handler.if.startsWith("Bash(git");
const allExec=Object.values(h.hooks).flat().every(g=>g.hooks.every(x=>x.command==="bash"&&Array.isArray(x.args)&&x.args.length>=1));
process.stdout.write(`${pre.matcher} ${ifok} ${allExec}`);
' "$H")
assert_eq "PreToolUse matcher is the tool name Bash" "Bash" "$matcher"
# Handler-level `if` scoped to git (broad enough to cover `git -C <repo> commit`; the
# script self-guard narrows to the commit subcommand).
assert_eq "commit gate uses handler-level if on git" "true" "$ifok"
assert_eq "all hooks use exec form (command:bash + args)" "true" "$execform"

# N10: no unquoted-shell-form command strings remain.
assert_false "no shell-form plugin-root command strings" grep -q '"command": *"\${CLAUDE_PLUGIN_ROOT}' "$H"

# B1/B3: strict validation (skip cleanly if the CLI is unavailable).
if command -v claude >/dev/null 2>&1; then
  assert_true "claude plugin validate --strict passes" claude plugin validate "$DAR_ROOT" --strict
else
  printf '  – claude CLI absent; skipping strict validation\n'
fi

finish
