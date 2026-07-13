#!/usr/bin/env bash
# PreToolUse(Bash) — auto-approve dar's OWN review commands so the Stop gate can
# always clear itself, including in headless (`claude -p`) sessions where nobody can
# answer a permission prompt (observed live: the gate blocked, the model tried
# `dar ripple` three times, every attempt was auto-rejected, and the bounded
# escalation fired — honest, but the review never ran).
#
# The approval is deliberately SURGICAL, fail-closed on any doubt:
#   • the command must be a SINGLE dar invocation — it must START with the dar
#     binary (no env-assignment prefixes) and contain NO shell metacharacters
#     (; | & < > $ ` \ newline), so nothing can ride along with the approval;
#   • the binary must be exactly `dar`, `~/.local/bin/dar`, or an absolute path
#     whose REAL location is a `bin/dar` inside a dual-agent-review checkout/cache
#     (a repo cannot shadow it with its own executable named dar);
#   • only READ-ONLY/review subcommands are approved: ripple, probe, scope,
#     plan-redteam, canary, verify, doctor. `dar trust`, `dar untrust`,
#     `dar baseline`, and `dar setup` are NEVER auto-approved — those are the
#     human-consent escape hatches (self-trusting a repo or re-framing the session
#     baseline must cost a human decision), so they fall through to the normal
#     permission flow.
# Anything that fails any check emits nothing: the normal permission system decides.

set -uo pipefail

command -v node >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

verdict="$(printf '%s' "$input" | node -e '
  let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(0); }
  const cmd = String((d.tool_input && d.tool_input.command) || "");
  if (!cmd) process.exit(0);
  // One plain invocation only: no chaining, substitution, redirection, or escapes.
  if (/[;|&<>$`\\\n]/.test(cmd)) process.exit(0);
  // Must START with the dar binary (optionally double-quoted). No env prefixes.
  const m = cmd.match(/^\s*("([^"]+)"|(\S+))\s+(\S+)([\s\S]*)$/);
  if (!m) process.exit(0);
  const bin = m[2] ?? m[3];
  const sub = m[4];
  const ALLOWED = new Set(["ripple", "probe", "scope", "plan-redteam", "canary", "verify", "doctor"]);
  if (!ALLOWED.has(sub)) process.exit(0);
  process.stdout.write(JSON.stringify({ bin, sub }));
' 2>/dev/null || true)"
[ -n "$verdict" ] || exit 0

BIN="$(printf '%s' "$verdict" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0)).bin)' 2>/dev/null)"
SUB="$(printf '%s' "$verdict" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0)).sub)' 2>/dev/null)"
[ -n "$BIN" ] || exit 0

# Resolve what would actually execute and require it to be a dual-agent-review
# bin/dar. `dar` bare → PATH lookup; a literal tilde path (from a message the model
# pasted verbatim) is expanded here since it never passed through a shell expansion;
# any other relative form is refused.
tilde='~'
case "$BIN" in
  dar) RESOLVED="$(command -v dar 2>/dev/null || true)";;
  /*)  RESOLVED="$BIN";;
  "${tilde}/"*) RESOLVED="${HOME}${BIN#"$tilde"}";;
  *)   exit 0;;
esac
[ -n "$RESOLVED" ] && [ -e "$RESOLVED" ] || exit 0
# Follow symlinks to the REAL file (BSD-safe loop; no readlink -f on macOS).
_seen=0
while [ -L "$RESOLVED" ] && [ "$_seen" -lt 8 ]; do
  _dir="$(cd -P "$(dirname "$RESOLVED")" 2>/dev/null && pwd)" || exit 0
  _tgt="$(readlink "$RESOLVED")" || exit 0
  case "$_tgt" in /*) RESOLVED="$_tgt";; *) RESOLVED="${_dir}/${_tgt}";; esac
  _seen=$((_seen + 1))
done
[ -x "$RESOLVED" ] || exit 0
case "$RESOLVED" in
  */dual-agent-review*/bin/dar) : ;;   # plugin cache, repo checkout, or versioned dir
  *) exit 0 ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"dual-agent-review: dar %s is the plugin'\''s own read-only review command (single invocation, verified binary)."}}\n' "$SUB"
exit 0
