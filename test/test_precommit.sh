#!/usr/bin/env bash
# B3 — precommit gate: self-guard, advisory/block modes, SHIP-receipt release,
# cross-repo target resolution, ambiguous-command refusal, session fingerprints.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "precommit gate (B3)"

export CLAUDE_PLUGIN_DATA; CLAUDE_PLUGIN_DATA="$(mktemp -d)"
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"

R="$(new_repo)"; OTHER="$(new_repo)"; trap 'rm -rf "$R" "$OTHER" "$CLAUDE_PLUGIN_DATA"' EXIT
echo '{"v":1}' > "$R/config.json"; git_commit "$R" init
echo '{"v":2}' > "$R/config.json"   # opaque control-file change → high blast
echo base > "$OTHER/readme.txt"; git_commit "$OTHER" init   # OTHER starts clean

ERR_F="$(mktemp)"
run_pre() { # MODE COMMAND_JSON
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$DAR_ROOT" DAR_ENFORCE="$1" \
    bash "$DAR_ROOT/scripts/precommit-gate.sh" >/dev/null 2>"$ERR_F"
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

# A SHIP receipt for exactly this state releases silently — in BOTH modes.
dar_write_receipt_fp "$R" "$(dar_diff_fingerprint "$R")" ship
rc=0; run_pre advise '{"tool_input":{"command":"git commit -m x"}}' || rc=$?
assert_eq "ship receipt releases (advise)" "0" "$rc"
rc=0; run_pre block '{"tool_input":{"command":"git commit -m x"}}' || rc=$?
assert_eq "ship receipt releases (block)" "0" "$rc"
# ...but a non-ship receipt does not.
dar_write_receipt_fp "$R" "$(dar_diff_fingerprint "$R")" revise
rc=0; run_pre block '{"tool_input":{"command":"git commit -m x"}}' || rc=$?
assert_eq "revise receipt does NOT release" "2" "$rc"
rm -f "$CLAUDE_PLUGIN_DATA"/receipt-*

# Cross-repo: `git -C OTHER commit` measures OTHER, not the session project.
rc=0; run_pre block "{\"tool_input\":{\"command\":\"git -C $OTHER commit -m x\"}}" || rc=$?
assert_eq "clean cross-repo target → allow despite dirty PROJ" "0" "$rc"
echo '{"v":9}' > "$OTHER/package.json"; git -C "$OTHER" add -A >/dev/null 2>&1
rc=0; run_pre advise "{\"tool_input\":{\"command\":\"git -C $OTHER commit -m x\"}}" || rc=$?
assert_eq "hot cross-repo target → advise" "1" "$rc"
assert_contains "cross-repo notice measured the target" "$(cat "$ERR_F")" "HIGH blast radius"

# Ambiguous directory changes → refuse to guess, say NOT measured.
rc=0; run_pre advise '{"tool_input":{"command":"cd /tmp && cd sub && git commit -m x"}}' || rc=$?
assert_eq "chained cd → advisory, not silent" "1" "$rc"
assert_contains "ambiguous notice says not-measured" "$(cat "$ERR_F")" "cannot determine"
# Every other repo-redirection construct we can't attribute → same refusal.
for cmd in \
  'git --git-dir=/other/.git --work-tree=/other commit -m x' \
  'GIT_DIR=/other/.git git commit -m x' \
  'env -C /other git commit -m x' \
  'bash -c "cd /other && git commit -m x"' \
  'git -C /other status && git commit -m x'
do
  rc=0; run_pre advise "$(node -e 'process.stdout.write(JSON.stringify({tool_input:{command:process.argv[1]}}))' "$cmd")" || rc=$?
  assert_eq "redirection refused: ${cmd%% *}…" "1" "$rc"
  assert_contains "…and says not-measured" "$(cat "$ERR_F")" "cannot determine"
done

# Session fingerprints: with a baseline, the receipt must be keyed to the SESSION
# fingerprint (a legacy receipt written for the same worktree does not match).
BF="$(dar_baseline_path "$R" sX)"
node "$DAR_ROOT/lib/baseline.mjs" capture --repo "$R" --out "$BF" >/dev/null
echo '{"w":1}' > "$R/tsconfig.json"
rc=0; run_pre advise '{"tool_input":{"command":"git commit -m x"},"session_id":"sX"}' || rc=$?
assert_eq "session hot change → advise" "1" "$rc"
dar_write_receipt_fp "$R" "$(DAR_HOME="$DAR_ROOT" dar_session_fingerprint "$R" "$BF")" ship
rc=0; run_pre block '{"tool_input":{"command":"git commit -m x"},"session_id":"sX"}' || rc=$?
assert_eq "session ship receipt releases" "0" "$rc"

finish
