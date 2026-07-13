#!/usr/bin/env bash
# dar doctor — verify the environment. Required: codex + node + git. graphify is
# an OPTIONAL accelerator; without it the built-in Node graph is used.
#
# Usage: dar doctor [--repo <path>]

set -uo pipefail
DAR_HOME="${DAR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

REPO=""; LIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2;;
    --live) LIVE=1; shift;;
    *) shift;;
  esac
done

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

# Wrapper-construction smoke test (finding #9): PATH presence is NOT enough — the
# Codex argv must actually build under `set -u` with model/effort unset (the default
# macOS Bash 3.2 crash path from finding #2). Never invokes codex.
# shellcheck source=/dev/null
source "${DAR_HOME}/config/defaults.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${DAR_HOME}/lib/codex.sh" 2>/dev/null || true
if declare -F dar_codex_selftest >/dev/null 2>&1; then
  check "codex wrapper builds argv (Bash empty-array safe)" dar_codex_selftest
else
  printf "  ✗ codex wrapper self-test unavailable (lib/codex.sh not loaded)\n"; bad=$((bad+1))
fi

# When run inside the plugin repo, validate the plugin + marketplace + hook config so
# a shipped regression (invalid manifest / hook schema) is caught here too.
if [[ -f "${DAR_HOME}/.claude-plugin/marketplace.json" ]] && command -v claude >/dev/null 2>&1; then
  check "plugin + marketplace validate (--strict)" claude plugin validate "${DAR_HOME}" --strict
fi

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

echo "reviewer (codex):"
# shellcheck source=/dev/null
source "${DAR_HOME}/config/defaults.sh"
# Effective model/effort (inherited from ~/.codex/config.toml unless forced), plus a
# FREE, LOCAL staleness check against codex's own model cache — no API call, no tokens.
node -e '
const fs=require("fs"), os=require("os"), path=require("path"), home=os.homedir();
let cfgModel=null, cfgEffort=null;
try{const t=fs.readFileSync(path.join(home,".codex","config.toml"),"utf8");
  cfgModel=(t.match(/^\s*model\s*=\s*"([^"]+)"/m)||[])[1]||null;
  cfgEffort=(t.match(/^\s*model_reasoning_effort\s*=\s*"([^"]+)"/m)||[])[1]||null;
}catch{}
const fM=process.env.DAR_CODEX_MODEL, fE=process.env.DAR_CODEX_EFFORT;
console.log(`  model=${fM||cfgModel||"(codex default)"}${fM?" (forced)":" (inherited)"}  effort=${fE||cfgEffort||"(codex default)"}  sandbox=read-only  web=${process.env.DAR_CODEX_WEBSEARCH}`);
if(!fM){ try{
  const models=(JSON.parse(fs.readFileSync(path.join(home,".codex","models_cache.json"),"utf8")).models)||[];
  const latest=models[0];
  if(latest && cfgModel && latest.slug!==cfgModel)
    console.log(`  ⚠ newer codex model available: ${latest.slug} (${latest.display_name}); you are on ${cfgModel} — update ~/.codex/config.toml to review with it`);
}catch{} }
' 2>/dev/null || printf "  (could not read codex config)\n"

# Opt-in LIVE check: actually invoke codex read-only over a trivial fixture and confirm
# it returns schema-valid JSON. Costs tokens, so it is off by default.
if [[ "$LIVE" == "1" ]]; then
  echo "live reviewer check (--live; invokes codex, read-only):"
  ( set -uo pipefail
    # shellcheck source=/dev/null
    source "${DAR_HOME}/lib/common.sh" >/dev/null 2>&1
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    git -C "$tmp" init -q
    printf '## The diff under review\n```\n+export const x = 1;\n```\n' > "$tmp/ctx.md"
    if dar_codex_run "${DAR_HOME}/prompts/ripple.md" "$tmp/ctx.md" "${DAR_HOME}/schemas/review.schema.json" "$tmp/out.json" "$tmp/err.txt" "$tmp" \
       && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$tmp/out.json" >/dev/null 2>&1; then
      printf "  ✓ codex returned schema-valid JSON\n"
    else
      # Surface the actual codex stderr/output INLINE before the temp dir is cleaned up,
      # so an auth/model failure is diagnosable (don't just say "see errors" then delete them).
      printf "  ✗ live codex review failed. codex stderr:\n"
      sed 's/^/      /' "$tmp/err.txt" 2>/dev/null | head -40
      [ -s "$tmp/out.json" ] && { printf "    (raw output:)\n"; sed 's/^/      /' "$tmp/out.json" 2>/dev/null | head -20; }
      exit 1
    fi
  ) || bad=$((bad+1))
fi

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
