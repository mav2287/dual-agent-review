#!/usr/bin/env bash
# dar doctor — verify the environment. Required: codex + node + git. graphify is
# an OPTIONAL accelerator; without it the built-in Node graph is used.
#
# Usage: dar doctor [--repo <path>]

set -uo pipefail
DAR_HOME="${DAR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

REPO=""
[[ "${1:-}" == "--repo" ]] && REPO="${2:-}"

ok=0; bad=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf "  ✓ %s\n" "$label"; ok=$((ok+1))
  else printf "  ✗ %s\n" "$label"; bad=$((bad+1)); fi
}

echo "dual-agent-review — environment"
echo "required:"
check "codex on PATH (reviewer/surveyor)" command -v codex
check "node on PATH (ships with Claude Code)" command -v node
check "git on PATH" command -v git

echo "optional (accelerator):"
if command -v graphify >/dev/null 2>&1; then
  printf "  ✓ graphify present — its richer graph is used when graphify-out/graph.json is current (at HEAD)\n"
  for plat in claude codex; do
    base="${HOME}/.${plat}"
    if ls -d "${base}/skills/graphify" "${base}/skills"/*graphify* >/dev/null 2>&1; then
      printf "  ✓ graphify installed for %s\n" "$plat"
    else
      printf "  ⚠ graphify not installed for %s — run 'dar setup' to add it\n" "$plat"
    fi
  done
else
  printf "  – graphify not installed (fine) — using the built-in Node graph\n"
fi

echo "reviewer config:"
# shellcheck source=/dev/null
source "${DAR_HOME}/config/defaults.sh"
printf "  model=%s effort=%s sandbox=read-only (hardcoded) web=%s\n" \
  "$DAR_CODEX_MODEL" "$DAR_CODEX_EFFORT" "$DAR_CODEX_WEBSEARCH"

if [[ -n "$REPO" ]]; then
  REPO="$(cd "$REPO" && pwd)"
  echo "target repo: $REPO"
  check "is a git repo" git -C "$REPO" rev-parse --git-dir
  if [[ -f "${REPO}/graphify-out/graph.json" ]]; then
    built="$(node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(process.argv[1]))||{}).built_at_commit||"?")' "${REPO}/graphify-out/graph.json" 2>/dev/null)"
    head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo '?')"
    if [[ "$built" == "$head" ]]; then printf "  ✓ graphify graph present and current (%s)\n" "${built:0:8}"
    else printf "  ⚠ graphify graph stale (built %s, HEAD %s) — probe falls back to the native graph; 'graphify update .' to use graphify\n" "${built:0:8}" "${head:0:8}"; fi
  else
    printf "  – no graphify graph — probe builds the graph in-house from the repo\n"
  fi
fi

echo
if [[ "$bad" -eq 0 ]]; then echo "all good ($ok required checks passed)"; exit 0
else echo "$bad required check(s) failed"; exit 1; fi
