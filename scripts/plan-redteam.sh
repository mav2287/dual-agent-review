#!/usr/bin/env bash
# Gate 2 — plan red-team. Codex adversarially attacks the integrator's WRITTEN
# plan against the scope map and the original issue, before any code is written.
#
# Usage: dar plan-redteam --repo <path> --plan <file> \
#            [--scope-map <file>] [--issue <file>]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

REPO="" PLAN="" SCOPE_MAP="" ISSUE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --plan) PLAN="$2"; shift 2;;
    --scope-map) SCOPE_MAP="$2"; shift 2;;
    --issue) ISSUE="$2"; shift 2;;
    *) echo "dar plan-redteam: unknown arg $1" >&2; exit 2;;
  esac
done
[[ -n "$REPO" && -n "$PLAN" ]] || { echo "dar plan-redteam: --repo and --plan required" >&2; exit 2; }
[[ -f "$PLAN" ]] || { echo "dar plan-redteam: plan file not found: $PLAN" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
dar_load_repo_config "$REPO"

RUN="$(dar_new_run plan-redteam)"
CTX="${RUN}/context.md"
{
  if [[ -n "$ISSUE" && -f "$ISSUE" ]]; then echo "## Original issue"; cat "$ISSUE"; echo; fi
  echo "## The plan under review"; cat "$PLAN"; echo
  if [[ -n "$SCOPE_MAP" && -f "$SCOPE_MAP" ]]; then
    echo "## Scope map (blast radius the plan must honor)"; cat "$SCOPE_MAP"; echo
    echo "Cross-check every consumer above against the plan. Each one the plan"
    echo "does not account for is a missed-consumer finding."
  fi
} > "$CTX"

OUT="${RUN}/redteam.json"; ERR="${RUN}/codex.err"
echo "── plan red-team (codex, read-only) … ──"
if dar_codex_run "${DAR_HOME}/prompts/plan-redteam.md" "$CTX" "${DAR_HOME}/schemas/plan-redteam.schema.json" "$OUT" "$ERR" "$REPO"; then
  VERDICT="$(dar_json verdict "$OUT")"
  echo "→ verdict: ${VERDICT}   (findings: $OUT)"
  dar_json findings "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0)).forEach(f=>console.log(`  [${f.severity}/${f.category}] ${f.claim}`))' 2>/dev/null || true
  [[ "$VERDICT" == "proceed" ]] || exit 3   # non-zero so callers/hooks can gate
else
  rc=$?; echo "dar plan-redteam: codex failed (rc=$rc); see $ERR" >&2; exit "$rc"
fi
