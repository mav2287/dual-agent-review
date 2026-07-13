#!/usr/bin/env bash
# PreToolUse gate on `git commit` — the plugin's default "behavior change".
#
# Runs ONLY the fast, deterministic blast-radius probe (no Codex, ~1s). When a
# high-blast change is about to be committed, it surfaces a notice so the change
# doesn't slip past the review loop. A matching SHIP receipt (the review already
# ran for exactly this state) releases the gate silently in every mode — the gate
# asks for a review, not for ceremony. FAIL-SECURE: if it cannot measure (node
# missing, probe error, unresolvable target repo), it advises rather than staying
# silent — uncertainty must not read as "clear".
#
# Note the Stop gate is the enforcement backstop: it measures the session delta
# against the SessionStart baseline, so committing a high-blast change does NOT
# launder it (the diff vs the baseline HEAD still covers committed work).
#
# Modes (env DAR_ENFORCE):
#   advise (default) — print a notice, let the commit proceed (exit 1)
#   block            — refuse the commit until a ship review exists (exit 2)
#   off              — silent (exit 0)

set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
MODE="${DAR_ENFORCE:-advise}"

[ "$MODE" = "off" ] && exit 0

emit() { # MESSAGE
  echo "$1" >&2
  [ "$MODE" = "block" ] && exit 2 || exit 1
}

# ── read the hook input: which command, which session, which repo? ────────────
# The hook's `if: "Bash(git *)"` already scopes this to git calls, but that filter is
# fail-OPEN — a command it can't parse runs the gate anyway. Parse the Bash command
# from stdin JSON: skip early ONLY when we can positively confirm there is no
# `git ... commit` in it; resolve `git -C <path>` and a leading `cd <path> &&` so the
# gate measures the repo actually being committed, not blindly the session project.
# On any doubt — no stdin, no node, parse failure — we do NOT skip: run the gate.
SID=""; CD_TARGET=""; C_TARGET=""; AMBIGUOUS="false"
_PARSER="$ROOT/lib/parse-commit-cmd.mjs"
if [ ! -t 0 ] && command -v node >/dev/null 2>&1 && [ -f "$_PARSER" ]; then
  _parsed="$(cat 2>/dev/null | node "$_PARSER" 2>/dev/null || true)"
  if [ -n "$_parsed" ]; then
    _has=""; _amb=""
    # \x1f field separator: command substitution strips NULs, and paths can hold
    # spaces/tabs — the unit separator survives both. Non-whitespace IFS preserves
    # empty fields on Bash 3.2.
    IFS=$'\x1f' read -r _has _amb CD_TARGET C_TARGET SID <<< "$_parsed"
    [ "$_has" = "0" ] && exit 0     # definitely not a git commit → nothing to measure
    [ "$_amb" = "1" ] && AMBIGUOUS="true"
  fi
fi

# shellcheck source=/dev/null
source "${ROOT}/lib/fingerprint.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/trust.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/thresholds.sh"
# Load thresholds + the hot-path list (exported) so the probe actually applies
# them; then a TRUSTED repo's .dar.thresholds. This hook must NOT execute the
# target repo's `.dar.config.sh` (arbitrary shell) — parsed calibration only.
# shellcheck source=/dev/null
[ -f "$ROOT/config/defaults.sh" ] && source "$ROOT/config/defaults.sh"

DARBIN="${ROOT}/bin/dar"

[ "$AMBIGUOUS" = "true" ] && emit "dual-agent-review: cannot determine which repository this commit targets (chained cd / unparsed -C) — the blast radius was NOT measured. Commit from the session's project directory, or review manually (\"${DARBIN}\" ripple)."

# Resolve the commit's actual target repo (leading `cd X && ...`, then `git -C Y`).
_resolve_into() { # BASE REL → absolute physical path, or empty
  local base="$1" rel="$2" tilde='~'
  # REL came out of a JSON string, so it never went through shell expansion —
  # expand a literal leading tilde ourselves.
  case "$rel" in
    "$tilde") rel="$HOME";;
    "$tilde"/*) rel="${HOME}${rel#"$tilde"}";;
  esac
  (cd "$base" 2>/dev/null && cd "$rel" 2>/dev/null && pwd -P) || true
}
TARGET="$PROJ"
if [ -n "$CD_TARGET" ]; then
  TARGET="$(_resolve_into "$PROJ" "$CD_TARGET")"
  [ -n "$TARGET" ] || emit "dual-agent-review: cannot resolve the commit's working directory ('${CD_TARGET}') — the blast radius was NOT measured; review manually before committing."
fi
if [ -n "$C_TARGET" ]; then
  TARGET="$(_resolve_into "$TARGET" "$C_TARGET")"
  [ -n "$TARGET" ] || emit "dual-agent-review: cannot resolve the commit's -C target ('${C_TARGET}') — the blast radius was NOT measured; review manually before committing."
fi
TOP="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" \
  || emit "dual-agent-review: the commit's target ('${TARGET}') is not a git repository dar can measure — review manually before committing."
# Re-point at the target repo ONLY when it is genuinely a different repo. When it is
# the same repo, keep the ORIGINAL project path: receipts and baselines are keyed by
# the path string the other gates use (CLAUDE_PROJECT_DIR), and rev-parse canonicalizes
# symlinks (/var → /private/var on macOS), which would silently break that key.
PTOP="$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null || echo "$PROJ")"
[ "$TOP" != "$PTOP" ] && PROJ="$TOP"

dar_load_thresholds "$PROJ"

# Can't measure without node → don't stay silent; advise.
command -v node >/dev/null 2>&1 || emit "dual-agent-review: node not found, cannot measure blast radius — review this change manually before committing."

# ── receipt: a ship review for exactly this state releases silently ──────────
BF=""
if [ -n "$SID" ]; then
  _bf="$(dar_baseline_path "$PROJ" "$SID")"
  [ -f "$_bf" ] && BF="$_bf"
fi
if [ -n "$BF" ]; then FP="$(dar_session_fingerprint "$PROJ" "$BF")"; else FP="$(dar_diff_fingerprint "$PROJ")"; fi
if [ -n "$FP" ] && dar_receipt_matches_fp "$PROJ" "$FP"; then exit 0; fi

# ── measure: staged files ∪ session delta (covers `git commit -a` / pathspecs) ─
UNSAFE="false"
_staged="$(git -C "$PROJ" diff --cached --name-only 2>/dev/null || true)"
_delta=""
if [ -n "$BF" ]; then
  _deltaj="$(node "$ROOT/lib/baseline.mjs" delta --repo "$PROJ" --baseline "$BF" 2>/dev/null || true)"
  _delta="$(printf '%s' "$_deltaj" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));if(d.ok)process.stdout.write(d.delta.join("\n"))}catch{}' 2>/dev/null || true)"
fi
FILES="$(printf '%s\n%s\n' "$_staged" "$_delta" | sort -u | grep -v '^$' || true)"
case "$FILES" in *,*) UNSAFE="true";; esac

if [ -n "$FILES" ] && [ "$UNSAFE" = "false" ]; then
  res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --files "$(printf '%s' "$FILES" | tr '\n' ',')" 2>/dev/null)" \
    || emit "dual-agent-review: blast-radius probe failed — review this change manually before committing."
elif [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null)" ]; then
  # Unsafe filenames or nothing enumerable but a dirty tree → measure everything.
  res="$(node "$ROOT/lib/blast-radius.mjs" --repo "$PROJ" --diff-base HEAD 2>/dev/null)" \
    || emit "dual-agent-review: blast-radius probe failed — review this change manually before committing."
else
  exit 0   # clean tree, nothing staged → the commit itself will be a no-op
fi

read -r survey fanout spread < <(
  printf '%s' "$res" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.survey} ${d.signals.fanout??"?"} ${d.signals.spread??"?"}`)}catch{process.stdout.write("true ? ?")}'
)

# survey=false → genuinely contained → allow silently.
[ "$survey" = "false" ] && exit 0

if [ -n "$BF" ]; then
  RIPPLE="\"${DARBIN}\" ripple --repo . --baseline \"${BF}\""
else
  RIPPLE="\"${DARBIN}\" ripple --repo . --diff-base HEAD"
fi
emit "dual-agent-review ⚠ HIGH blast radius: fan-out ${fanout} across ${spread} subsystems and no shipping review for this state. Run the Codex check before committing — ${RIPPLE} (or /codex:adversarial-review for a deeper manual pass). A SHIP verdict clears this gate. Set DAR_ENFORCE=off to silence, =block to enforce."
