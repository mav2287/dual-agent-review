#!/usr/bin/env bash
# dar setup — install dar's skill + slash commands, and optionally wire in graphify.
#
# graphify is OPTIONAL — the probe builds its own graph in pure Node. This always
# installs dar's own skill + slash commands. Only if graphify is already on PATH does
# it install graphify's skill into both agents and (with --repo) build/refresh that
# repo's graphify graph and add its freshness hooks. Nothing here installs graphify
# itself.
#
# Usage:
#   dar setup                 # install dar's skill/commands (+ graphify skill if present)
#   dar setup --repo <path>   # + if graphify is present, build/refresh that repo's graph + hooks
#   dar setup --no-hooks      # skip graphify's git freshness hooks

set -uo pipefail
DAR_HOME="${DAR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

REPO=""; WITH_HOOKS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --no-hooks) WITH_HOOKS=0; shift;;
    *) echo "dar setup: unknown arg $1" >&2; exit 2;;
  esac
done

echo "── installing dar (skill + slash commands, global) ──"
bash "${DAR_HOME}/install.sh"

if command -v graphify >/dev/null 2>&1; then
  echo "── graphify present: installing into both agents (optional accelerator) ──"
  graphify install --platform claude || echo "  ⚠ graphify install --platform claude failed"
  graphify install --platform codex  || echo "  ⚠ graphify install --platform codex failed"
  if [[ -n "$REPO" ]]; then
    REPO="$(cd "$REPO" && pwd)"
    echo "── target repo: $REPO ──"
    if [[ -f "${REPO}/graphify-out/graph.json" ]]; then
      echo "  refreshing graphify graph (graphify update — skips LLM clustering)…"
      ( cd "$REPO" && graphify update . ) || echo "  ⚠ graph update failed"
    else
      echo "  building graph (first time)…"
      ( cd "$REPO" && graphify . ) || echo "  ⚠ graph build failed"
    fi
    if [[ "$WITH_HOOKS" -eq 1 ]]; then
      echo "  installing graphify git hooks (keep the graph fresh)…"
      ( cd "$REPO" && graphify hook install ) || echo "  ⚠ graphify hook install failed"
    fi
  fi
else
  echo "── graphify not installed — that's fine; the built-in Node graph is used. ──"
  echo "   (install graphify later for a richer graph; re-run 'dar setup' to wire it in.)"
fi

echo
echo "verify: dar doctor${REPO:+ --repo $REPO}"
