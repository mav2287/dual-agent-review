# shellcheck shell=bash
# dual-agent-review — default configuration.
#
# Layering (weakest to strongest):
#   1. these defaults
#   2. <repo>/.dar.thresholds — plain KEY=VALUE, PARSED not executed, trusted repos
#      only (lib/thresholds.sh) — the only per-repo tuning the automatic hooks read
#   3. the user's environment — always wins over a repo file
#   4. <repo>/.dar.config.sh — arbitrary shell, trusted repos + manual gates ONLY
#      (sourced after this file by lib/common.sh's dar_load_repo_config)
#
# DAR_DEFAULTED records which keys THIS file supplied (vs. the user's environment),
# so lib/thresholds.sh can let a repo file override defaults without ever overriding
# an explicit user setting.
#
# The reviewer is the Codex CLI; the blast-radius graph is built in pure Node, with
# graphify used as an accelerator only when its graph is present and current (at HEAD).
#
# Every value the Node probe reads is `export`ed — without that, a child `node`
# process sees none of it and the hot-path tripwire silently disappears.

DAR_DEFAULTED=""
dar_default() { # VAR VALUE — set VAR only when unset/empty, and remember that we did.
  local _v="$1"
  if [ -z "$(eval "printf '%s' \"\${${_v}:-}\"")" ]; then
    eval "${_v}=\"\$2\""
    DAR_DEFAULTED="${DAR_DEFAULTED} ${_v}"
  fi
  export "${_v?}"
}

# ── Reviewer (Codex) ────────────────────────────────────────────────────────
# Model + effort are INHERITED from ~/.codex/config.toml by default (empty = don't
# pass -c, so codex uses your configured model). Set these only to FORCE a specific
# reviewer model/effort. Pinning is avoided on purpose — a hardcoded model goes stale.
export DAR_CODEX_MODEL="${DAR_CODEX_MODEL:-}"
export DAR_CODEX_EFFORT="${DAR_CODEX_EFFORT:-}"
# web_search stays off: a code review shouldn't hit the internet. (dar policy)
export DAR_CODEX_WEBSEARCH="${DAR_CODEX_WEBSEARCH:-disabled}"
# NOTE: the sandbox is HARDCODED to read-only in lib/codex.sh and is deliberately
# NOT configurable here — an adversarial reviewer must never mutate what it judges.

# ── Blast-radius triage thresholds (calibrate per repo; bias toward surveying) ─
dar_default DAR_FANOUT_THRESHOLD 150   # consumer files → survey
dar_default DAR_SPREAD_THRESHOLD 3     # subsystems spanned → survey
dar_default DAR_BFS_DEPTH 3            # reverse-dependency depth
dar_default DAR_MIN_CONFIDENCE 0.4     # native-graph trust floor

# ── Session-baseline gating ─────────────────────────────────────────────────
# The Stop gate measures the SESSION DELTA against the baseline captured at
# SessionStart. A delta larger than DAR_MAX_DELTA_FILES is treated as unmeasurable
# (block-once, with a re-baseline hint) rather than silently skipped.
dar_default DAR_MAX_STOP_BLOCKS 4
dar_default DAR_MAX_DELTA_FILES 500
# DAR_EXCLUDE / DAR_INERT_EXTRA / DAR_OPAQUE_EXTRA: newline-separated regex lists,
# empty by default; per-repo values come from a TRUSTED repo's .dar.thresholds.
dar_default DAR_EXCLUDE ""
dar_default DAR_INERT_EXTRA ""
dar_default DAR_OPAQUE_EXTRA ""

# ── Hot-path tripwire ───────────────────────────────────────────────────────
# Changing any file matching these ALWAYS surveys, regardless of graph fan-out.
# Framework-generic high-cost surfaces; add YOUR app's danger zones via
# DAR_HOTPATHS_EXTRA in the target repo's .dar.thresholds (or .dar.config.sh).
# A plain single-quoted multi-line string — no here-doc, so it can't fail in a
# read-only/no-TMPDIR shell and silently leave the list empty.
if [ -z "${DAR_HOTPATHS:-}" ]; then
  DAR_HOTPATHS='(^|/)migrations?/
schema\.(prisma|sql)$
(^|/)auth(\.|/|-|z)
(^|/)middleware(\.|/)
(^|/)security/
package(-lock)?\.json$
pnpm-lock\.yaml$
yarn\.lock$
(^|/)Dockerfile
docker-compose
(^|/)\.github/workflows/
(^|/)\.env
tsconfig.*\.json$
(^|/)prompts/
(^|/)skills/
(^|/)commands/
(^|/)hooks?/
(^|/)\.claude/
(^|/)\.codex/
(^|/)(CLAUDE|AGENTS|GEMINI)\.md$'
  DAR_DEFAULTED="${DAR_DEFAULTED} DAR_HOTPATHS"
fi
export DAR_HOTPATHS

# ── Iteration caps (anti-thrash) ────────────────────────────────────────────
export DAR_MAX_PLAN_REDTEAM_CYCLES="${DAR_MAX_PLAN_REDTEAM_CYCLES:-1}"
export DAR_MAX_IMPL_REVIEW_CYCLES="${DAR_MAX_IMPL_REVIEW_CYCLES:-2}"

# ── Runtime layout ──────────────────────────────────────────────────────────
export DAR_HOME="${DAR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Run artifacts (scope maps, plan/diff review context) hold TARGET-repo material —
# keep them in a user-private state dir, NEVER inside this tool's repo/plugin dir,
# so a target repo's review data can't end up committed here.
export DAR_RUNS_DIR="${DAR_RUNS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dual-agent-review/runs}"
