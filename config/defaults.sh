# shellcheck shell=bash
# dual-agent-review — default configuration.
#
# Overridable per-target-repo by a `.dar.config.sh` in the repo root; it is
# sourced AFTER this file (see lib/common.sh), so it wins.
#
# The reviewer is the Codex CLI; the blast-radius graph is built in pure Node, with
# graphify used as an accelerator only when its graph is present and current (at HEAD).
#
# Every value the Node probe reads is `export`ed — without that, a child `node`
# process sees none of it and the hot-path tripwire silently disappears.

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
export DAR_FANOUT_THRESHOLD="${DAR_FANOUT_THRESHOLD:-150}"   # consumer files → survey
export DAR_SPREAD_THRESHOLD="${DAR_SPREAD_THRESHOLD:-3}"     # subsystems spanned → survey
export DAR_BFS_DEPTH="${DAR_BFS_DEPTH:-3}"                   # reverse-dependency depth
export DAR_MIN_CONFIDENCE="${DAR_MIN_CONFIDENCE:-0.4}"       # native-graph trust floor

# ── Hot-path tripwire ───────────────────────────────────────────────────────
# Changing any file matching these ALWAYS surveys, regardless of graph fan-out.
# Framework-generic high-cost surfaces; add YOUR app's danger zones in the target
# repo's .dar.config.sh (see examples/example.dar.config.sh).
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
