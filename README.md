# dual-agent-review (`dar`)

A Claude Code plugin that adds an automatic **Codex check-and-balance** to your
normal workflow.

Claude is a strong planner and a focused, narrow-scope implementer — but that same
narrow focus is where ripple bugs hide (a change that quietly breaks a consumer, an
auth path, or an invariant off to the side). Codex is better at the wide view — the
surrounding repo and the blast radius. This plugin pairs the two: when Claude makes
a change big enough to matter, it has **Codex review it as an independent adversary**
before the work is called done. You install it and keep working the way you already
do; the second opinion shows up on its own when a change warrants it.

## What it does

- **Decides when review is worth it.** A fast dependency-graph probe measures a
  change's real **blast radius** — how many files/subsystems depend on it — instead
  of using diff size. A one-line change to a hot symbol gets reviewed; a 300-line
  leaf change doesn't.
- **Enforces the review automatically.** A `Stop` hook runs after Claude finishes: on
  a high-blast change it blocks completion **until a `dar ripple` review has returned a
  `ship` verdict for that exact diff** (the receipt is keyed to a fingerprint of the
  tracked diff *and* untracked file contents, so it can't be satisfied by ignoring
  findings; a `block`/`revise` review does not clear the gate). Fixing findings changes
  the diff and forces a fresh review. If the same unshipped diff is blocked repeatedly,
  the gate stops looping, records an auditable `blocked-unresolved` state, and escalates
  loudly to you rather than silently letting the change through. Contained changes pass
  silently. A once-per-session `UserPromptSubmit` reminder nudges you to run the upstream
  gates (`dar scope`, `dar plan-redteam`) on high-blast work, since those can't be
  hook-enforced.
- **Stays a check, not a rubber stamp.** Codex runs read-only and adversarially; an
  on-demand `dar canary` exercises the reviewer on a planted fail-open fixture to
  confirm it still specifically identifies that hole. The automatic gate enforces review
  *workflow* state — that an independent review ran and shipped — **not** that your tests
  pass. Your own deterministic gates (tests/typecheck/lint, via `dar verify`) remain the
  real merge authority — never a model's "looks good."

## Install

```
/plugin marketplace add mav2287/dual-agent-review
/plugin install dual-agent-review
```

You need **Claude Code** (this is a plugin for it) and the **Codex CLI** (the
reviewer); `node` and `git` must be on PATH. On first session the plugin sets itself
up: it puts the `dar` CLI on PATH for the session and best-effort installs the
official `openai/codex-plugin-cc` (so the review can run via `/codex:adversarial-review`).
The blast-radius graph is built in pure Node — nothing is built inside your repos.
[graphify](https://pypi.org/project/graphify/) is fully optional: if you already have
it, `dar setup` will wire it in as a richer accelerator, but the plugin never installs
or runs it on its own. Run `dar doctor --repo <path>` to check the environment.

After that the review fires on its own when a change is big enough — you don't type a
review command yourself. `DAR_ENFORCE=off` turns the automation off; `block` makes the
commit gate refuse instead of advise. The slash commands below are optional.

## The graph backend

The blast-radius probe is built on an **in-house pure-Node dependency graph**
(`lib/graph.mjs`) — JS/TS (with tsconfig path aliases) and shell resolve precisely;
other languages fail safe by surveying more. The native graph is **always** the
authority for whether a changed file is resolved. If graphify has produced a graph and
it is **current** (built at `HEAD`), `dar` uses it **additively** — it may only *add*
dependency edges (between files the native graph already tracks), never remove fan-out
or mark a file resolved. So graphify can make the gate more conservative, never less; a
stale graph is simply ignored. That keeps the same fail-secure contract with or without
graphify.

## Optional manual commands

The automatic gate covers the after-the-fact case. When you want to run the full
loop deliberately (e.g. before a large change), the pieces are available by hand —
the `dual-agent-review` skill orchestrates them, or run them directly:

```bash
dar probe        --repo P --diff-base main          # survey vs skip? (fast, no LLM)
dar scope        --repo P --task "..." --diff-base main   # map the blast radius first
dar plan-redteam --repo P --plan plan.md            # Codex attacks the plan, pre-code
dar ripple       --repo P --diff-base main          # post-diff independent review
dar verify       --repo P                           # run the repo's tests/typecheck/lint gates
dar canary                                          # is the reviewer still sharp?
```

The same gates are available as slash commands. Installed as a plugin, they are
namespaced by the plugin name:

```
/dual-agent-review:dar-scope
/dual-agent-review:dar-plan-redteam
/dual-agent-review:dar-ripple
/dual-agent-review:dar-verify
/dual-agent-review:dar-review
```

(The bare `/dar-scope` … forms apply only to the CLI-only install below, which symlinks
the commands into `~/.claude/commands` without a plugin namespace.)

## How the gate decides

The probe computes each changed file's **consumer set** (reverse-dependency
traversal) and surveys if any of: fan-out over threshold, subsystem spread over
threshold, a **hot-path** file (auth, migrations, shared plumbing…), an **unresolved**,
**unsupported-language**, or **opaque control-plane** file (a plugin manifest, schema,
CI config, lockfile — anything non-code we can't prove has zero blast radius; only
genuinely inert docs/assets are treated as contained), **low graph confidence** near the
change, or **any probe/config/graph failure** (unreadable graph, bad hot-path regex, an
undiffable state). It skips **only** on positive proof of containment — file presence in
the repo is never treated as that proof. A false skip is an unbounded bug; a false
survey is a few bounded minutes, so the gate is deliberately biased toward reviewing.

## Security & trust boundary

- **`dar`'s Codex review commands are hard read-only.** When `dar` invokes Codex
  (scope/plan-redteam/ripple/canary), it uses a frozen absolute path with `-s read-only`
  hardcoded; a repo's config cannot widen the sandbox, mutate `PATH`, or shadow the
  binary to escape it. (The optional `/codex:adversarial-review` route runs under the
  Codex plugin's own settings, not `dar`'s.)
- **`.dar.config.sh` is executed as shell** — like direnv, git hooks, or
  `package.json` scripts. Only run the manual gates on a repo you trust enough to run
  Claude Code / Codex on. `DAR_NO_REPO_CONFIG=1` refuses to source it; the auto-firing
  commit hook **never** sources it (defaults only).
- **Run artifacts** (scope maps, diffs) go to `${XDG_STATE_HOME:-~/.local/state}/dual-agent-review/runs`,
  not inside a repo, so one repo's review material can't leak into another.

## Layout

```
.claude-plugin/      plugin.json + marketplace.json (Claude Code plugin manifest)
hooks/hooks.json     Stop gate (hard-verified review) + UserPromptSubmit advisory + SessionStart bootstrap + git-commit gate
bin/dar              CLI entrypoint (added to the Claude session's PATH by the plugin)
lib/graph.mjs        the in-house pure-Node dependency graph (default backend)
lib/blast-radius.mjs the survey-vs-skip probe (native graph, or graphify if current)
lib/codex.sh         Codex wrapper for dar's scope/plan-redteam/ripple/canary (read-only, absolute-path)
lib/fingerprint.sh   diff fingerprint + review receipt (how the Stop gate hard-verifies)
scripts/             stop-gate, prompt-advisory, precommit-gate, bootstrap; gates (scope/plan-redteam/ripple); canary, setup, doctor
schemas/             structured-output JSON Schemas (scope, plan-redteam, review)
prompts/             adversarial role prompts (skepticism-first, no style nits)
skills/dual-agent-review/SKILL.md   orchestration skill (the loop, caps, escalation)
commands/            Claude Code slash commands
config/defaults.sh   thresholds + hot-path patterns (override per repo)
examples/            per-repo config overrides
docs/                the design rationale, evidence, and calibration guide
```

## Without the plugin (CLI only)

```bash
git clone https://github.com/mav2287/dual-agent-review.git && cd dual-agent-review
./install.sh            # symlinks `dar` onto PATH + skill/commands into ~/.claude
dar setup --repo P      # if graphify is already installed: wire it into both agents,
                        # build/refresh its graph, and add its freshness hooks
```

See `docs/dual-agent-workflow.md` for the design rationale, the evidence behind it,
and the per-repo calibration guide.
