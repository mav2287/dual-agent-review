#!/usr/bin/env bash
# approve-dar hook — auto-approves ONLY dar's own review commands: single plain
# invocation, verified binary location, review-subcommand allowlist. Everything
# else emits NOTHING (normal permission flow decides). The human escape hatches
# (trust/untrust/baseline/setup) must never be self-approvable.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "dar self-approval hook (headless clearing)"

H="$DAR_ROOT/scripts/approve-dar.sh"
run_approve() { # COMMAND_STRING → stdout of the hook
  node -e 'process.stdout.write(JSON.stringify({tool_input:{command:process.argv[1]}}))' "$1" \
    | bash "$H" 2>/dev/null
}

DARBIN="$DAR_ROOT/bin/dar"

# Approved: the plugin's own review commands, plain and absolute (quoted or not).
out="$(run_approve "\"$DARBIN\" ripple --repo . --baseline \"/tmp/some base/file\"")"
assert_contains "quoted abs dar ripple → allow" "$out" '"permissionDecision":"allow"'
out="$(run_approve "$DARBIN probe --repo .")"
assert_contains "abs dar probe → allow" "$out" '"permissionDecision":"allow"'
out="$(run_approve "$DARBIN canary")"
assert_contains "abs dar canary → allow" "$out" '"permissionDecision":"allow"'

# Bare `dar` resolves via PATH — approved only when PATH's dar IS the plugin's.
out="$(node -e 'process.stdout.write(JSON.stringify({tool_input:{command:"dar verify --repo ."}}))' | PATH="$DAR_ROOT/bin:$PATH" bash "$H" 2>/dev/null)"
assert_contains "bare dar on plugin PATH → allow" "$out" '"permissionDecision":"allow"'

# NEVER approved: the human-consent escape hatches.
assert_eq "dar trust → no self-approval" "" "$(run_approve "$DARBIN trust --repo .")"
assert_eq "dar untrust → no self-approval" "" "$(run_approve "$DARBIN untrust --repo .")"
assert_eq "dar baseline → no self-approval" "" "$(run_approve "$DARBIN baseline --repo .")"
assert_eq "dar setup → no self-approval" "" "$(run_approve "$DARBIN setup")"

# NEVER approved: anything that could ride along with the approval.
assert_eq "chained command → refused" "" "$(run_approve "$DARBIN ripple --repo . ; rm -rf /tmp/x")"
assert_eq "pipe → refused" "" "$(run_approve "$DARBIN ripple --repo . | tee /tmp/x")"
assert_eq "subshell → refused" "" "$(run_approve "\$(pwd)/bin/dar ripple --repo .")"
assert_eq "redirection → refused" "" "$(run_approve "$DARBIN ripple --repo . > /tmp/x")"
assert_eq "env-prefixed → refused" "" "$(run_approve "DAR_ENFORCE=off $DARBIN ripple --repo .")"

# NEVER approved: an impostor binary outside a dual-agent-review tree.
FAKE="$(mktemp -d)/bin"; mkdir -p "$FAKE"; printf '#!/bin/sh\n' > "$FAKE/dar"; chmod +x "$FAKE/dar"
assert_eq "impostor dar path → refused" "" "$(run_approve "$FAKE/dar ripple --repo .")"
rm -rf "$(dirname "$FAKE")"

# Symlink into the plugin resolves and approves (the ~/.local/bin/dar shape).
LNK="$(mktemp -d)"; ln -s "$DARBIN" "$LNK/dual-agent-review-link"
out="$(run_approve "$LNK/dual-agent-review-link doctor")"
# (link name is irrelevant; the RESOLVED target must be a dual-agent-review bin/dar)
assert_contains "symlink to plugin dar → allow" "$out" '"permissionDecision":"allow"'
rm -rf "$LNK"

finish
