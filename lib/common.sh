# shellcheck shell=bash
# dual-agent-review — shared harness sourced by every gate script.

set -euo pipefail

DAR_HOME="${DAR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DAR_HOME

# Freeze the CANONICAL plugin root — derived directly from THIS file's location, not
# from the (env-overridable) DAR_HOME — and make it readonly BEFORE any target repo's
# .dar.config.sh can run. The wrapper reload in dar_load_repo_config sources from this
# immutable path, so a hostile config that reassigns DAR_HOME cannot redirect the
# reload at an attacker-controlled lib/codex.sh. Do NOT trust a pre-set value.
DAR_CANONICAL_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DAR_CANONICAL_HOME

# Base config, then per-target-repo override (.dar.config.sh) if present.
# shellcheck source=/dev/null
source "${DAR_HOME}/config/defaults.sh"
# shellcheck source=/dev/null
source "${DAR_HOME}/lib/codex.sh"

# Resolve the Codex executable to an ABSOLUTE path NOW — before any target repo's
# .dar.config.sh can run — and freeze it. The wrapper invokes it by this path, so a
# hostile repo config cannot escape the read-only sandbox via PATH mutation or a
# `command`/`codex` function override.
if [ -z "${DAR_CODEX_BIN:-}" ]; then
  DAR_CODEX_BIN="$(command -v codex 2>/dev/null || true)"
fi
# Validate: must be an ABSOLUTE path to an EXECUTABLE. `command -v` can return a
# function name, alias, or bare/relative name; a pre-set env value is untrusted.
# Anything that fails this is discarded → the wrapper reports codex-not-found and
# the review fails closed rather than running an unknown "codex".
case "$DAR_CODEX_BIN" in
  /*) [ -x "$DAR_CODEX_BIN" ] || DAR_CODEX_BIN="" ;;
  *)  DAR_CODEX_BIN="" ;;
esac
readonly DAR_CODEX_BIN

# dar_load_repo_config REPO — layer the target repo's overrides on top of defaults.
#
# TRUST BOUNDARY: `.dar.config.sh` is executed as shell (like direnv, git hooks, or
# package.json scripts). Only run the manual review gates on a repo you already
# trust enough to run Claude Code / Codex on. Set DAR_NO_REPO_CONFIG=1 to refuse
# to source it (defaults-only). The auto-firing commit hook never sources it.
dar_load_repo_config() {
  local repo="$1"
  [[ "${DAR_NO_REPO_CONFIG:-0}" == "1" ]] && return 0
  if [[ -f "${repo}/.dar.config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${repo}/.dar.config.sh"
    # Re-assert the canonical Codex wrapper AFTER repo config: a repo's config
    # runs arbitrary shell and could otherwise redefine dar_codex_run to escape
    # the read-only sandbox. Reload from the FROZEN canonical root (not DAR_HOME,
    # which the config could have mutated) so our definition is authoritative.
    # shellcheck source=/dev/null
    source "${DAR_CANONICAL_HOME}/lib/codex.sh"
  fi
}

# dar_new_run GATE — create and echo a fresh run directory.
dar_new_run() {
  local gate="$1"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local dir="${DAR_RUNS_DIR}/${stamp}-${gate}-$$"
  mkdir -p "$dir"
  echo "$dir"
}

# dar_probe REPO [EXTRA ARGS...] — run the blast-radius probe, echo its JSON.
dar_probe() {
  local repo="$1"; shift
  node "${DAR_HOME}/lib/blast-radius.mjs" --repo "$repo" "$@"
}

# dar_json FIELD FILE — read a top-level field from a JSON file (via node, no jq dep).
dar_json() {
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8"));const v=process.argv[1].split(".").reduce((a,k)=>a==null?a:a[k],d);process.stdout.write(typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}
