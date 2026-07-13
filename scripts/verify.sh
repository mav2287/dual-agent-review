#!/usr/bin/env bash
# dar verify — run the repo's OWN deterministic merge gates (typecheck, lint, tests).
#
# These are the REAL merge authority. dar's AUTOMATIC gates (blast-radius survey, Stop
# ripple check) enforce review WORKFLOW state — that an independent review ran and
# shipped — NOT that tests/typecheck/lint pass (finding #17). This command is opt-in and
# repo-configured: set DAR_TEST_CMD / DAR_TYPECHECK_CMD / DAR_LINT_CMD in the target
# repo's .dar.config.sh. Unconfigured → it explains how to configure and exits 0.
#
# TRUST: like the other manual gates, this sources .dar.config.sh (arbitrary shell) and
# runs the configured commands. Only run it on a repo you trust.
#
# Usage: dar verify --repo <path>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set +e  # we drive control flow and exit codes ourselves; don't abort mid-gate

REPO=""; ALLOW_UNCONFIGURED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --allow-unconfigured) ALLOW_UNCONFIGURED=1; shift;;
    *) echo "dar verify: unknown arg $1" >&2; exit 2;;
  esac
done
[[ -n "$REPO" ]] || { echo "dar verify: --repo required" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
dar_load_repo_config "$REPO"

# Ordered gates: label → env var holding the command.
gates=("typecheck:DAR_TYPECHECK_CMD" "lint:DAR_LINT_CMD" "tests:DAR_TEST_CMD")
configured=0 failed=0
for g in "${gates[@]}"; do
  label="${g%%:*}"; var="${g#*:}"; cmd="${!var:-}"
  [ -n "$cmd" ] || continue
  configured=$((configured + 1))
  echo "── ${label}: ${cmd} ──"
  if ( cd "$REPO" && eval "$cmd" ); then
    echo "✓ ${label} passed"
  else
    echo "✗ ${label} FAILED (rc=$?)"; failed=$((failed + 1))
  fi
done

if [[ "$configured" -eq 0 ]]; then
  cat >&2 <<'EOF'
dar verify: no deterministic gates configured. These are the REAL merge authority and
are repo-specific, so set them in this repo's .dar.config.sh, e.g.:
  export DAR_TYPECHECK_CMD="npm run typecheck"
  export DAR_LINT_CMD="npm run lint"
  export DAR_TEST_CMD="npm test"
(dar's automatic gates enforce review workflow state, not test/lint/typecheck results.)
EOF
  # "No gates configured" is NOT success for something billed as the merge authority —
  # fail unless the caller explicitly opts in (a genuinely gate-less repo passes --allow-unconfigured).
  if [[ "$ALLOW_UNCONFIGURED" -eq 1 ]]; then
    echo "dar verify: no gates configured; --allow-unconfigured set → treating as pass." >&2
    exit 0
  fi
  echo "dar verify: refusing to report success with no gates configured (use --allow-unconfigured to override)." >&2
  exit 3
fi

echo
if [[ "$failed" -eq 0 ]]; then
  echo "dar verify: all ${configured} gate(s) passed"; exit 0
else
  echo "dar verify: ${failed} of ${configured} gate(s) FAILED"; exit 1
fi
