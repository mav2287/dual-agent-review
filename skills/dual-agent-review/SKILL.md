---
name: dual-agent-review
description: >-
  Run the Claude-primary / Codex-surveyor review loop on a change. Use whenever
  you are about to plan or have just implemented a non-trivial change and want
  cross-vendor adversarial review gated by real blast radius. Orchestrates the
  `dar` CLI (blast-radius probe → scope survey → plan red-team → ripple check →
  verify) with iteration caps and escalation.
---

# Dual-agent review loop

You (Claude) are the **integrator** — eyes on the task. Codex is the **surveyor /
adversary** — wide repo view, run read-only via the `dar` CLI. Neither reviews its
own work; deterministic gates (tests/typecheck/etc.) are the final merge authority,
never a model's "looks good."

**The after-the-fact review is automatic; the upstream gates are deliberate.** A
`Stop` hook fires after you respond: on a high-blast change it blocks completion and
tells you to run the adversarial review before finishing. **When you see that block,
do exactly what it says** — run `/codex:adversarial-review` (preferred) or
`dar ripple --repo . --diff-base HEAD`, address any real findings, then finish. The
scope-survey and plan-red-team gates below are NOT automatic — run them deliberately
when you want the wide view *before* a large change; the Stop hook covers the
post-change case on its own.

`REPO` below is the target repo root (usually `$(pwd)`). Every `dar` call is a
normal Bash tool call.

## The loop

**Gate 1 — Scope survey (before you plan).**
Run `dar scope --repo REPO --task "<what you intend to change>" --diff-base <ref>`.
- Prints `SKIP` → the change is provably contained (low fan-out, single subsystem, no
  hot-path file, all changed files resolved in a supported language, sufficient graph
  confidence). Proceed to plan normally; no survey needed.
- Prints a scope map → **plan within its `plan_constraints`.** Treat the consumers
  and invariants it lists as requirements, not suggestions.

**Gate 2 — Plan red-team (after you write the plan, before code).**
Write your plan to a file, then
`dar plan-redteam --repo REPO --plan <plan.md> --scope-map <scope-map.json> --issue <issue>`.
- `verdict: proceed` → implement.
- `verdict: revise|block` → for each finding, classify it: **confirmed** (fix the
  plan), **false-positive-with-evidence** (record why), **accepted-risk** (needs a
  human note), or **needs-human** (stop, ask the owner). Re-run **at most once**
  (`DAR_MAX_PLAN_REDTEAM_CYCLES`). Do not loop to consensus.

**Gate 3 — Implement.** Write the code within the red-teamed plan. Add outcome-level
tests for the behavior AND the fail paths, or state explicitly that no runnable test
exists and why.

**Gate 4 — Ripple check (after the diff).**
`dar ripple --repo REPO --diff-base <ref> --scope-map <scope-map.json>`.
It re-measures the ACTUAL diff's impact and compares to the scope map.
- `scope_conformance.respected_scope_map: false` or `out_of_frame_touches` non-empty
  → the change escaped its frame; investigate before anything else.
- Fix `block`/`revise` findings, re-run **at most twice** (`DAR_MAX_IMPL_REVIEW_CYCLES`).

**Gate 5 — Verify + merge (manual policy, not enforced by any script).** Run the
repo's deterministic gates (lint, typecheck, tests, mutation, migration-lint, i18n).
Then a **fresh** Claude self-audit (a subagent, not this context). Do not merge unless:
deterministic gates green **AND** Claude self-audit clean **AND** Codex `ship` **AND**
no unresolved accepted-risk.

## Reconciliation & escalation (do not skip)
- **Disagreement is a signal, not a vote.** When you and Codex conflict, gather
  deterministic evidence first — run the test, open the anchor, run `dar probe`. Do
  NOT debate to consensus; multi-agent debate converges wrong.
- **Escalate, don't spin.** Unresolved disagreement on a high-blast-radius or
  security-sensitive change goes to the human owner — not another review round.
- **Stop criteria.** Past the cycle caps, or if the same finding recurs twice with
  no progress, stop and escalate. If a reviewing context has been corrected twice,
  `/clear` it and restart with a sharper prompt.

## Anti-habituation
Every `dar` Codex verdict carries a `coverage` block (what it inspected / did not). If
coverage shrinks while verdicts stay green, scrutiny is decaying — run `dar canary`
(a seeded known fault) to confirm the reviewer still catches planted defects. A
reviewer that misses the canary is not trustworthy until it passes a fresh one.
