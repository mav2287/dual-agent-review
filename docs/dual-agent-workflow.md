# The dual-agent review loop — design, evidence, calibration

## Premise
Two frontier coding agents with different strengths:
- **Claude Code** — the *integrator*: plans and writes the change, eyes on the task.
- **Codex (gpt-5.5)** — the *surveyor/adversary*: wide repo view, read-only, run
  through `dar`.

The narrow view is what ships bugs (missed consumers, ripple, fail-secure holes).
So Codex's breadth is inserted **upstream** (map the terrain before Claude tunnels
in) **and** downstream (independent check that the change stayed in bounds).

## The five gates
1. **Scope survey** (Codex, before the plan) — map the blast radius; emit the
   `plan_constraints` the plan must honor.
2. **Plan red-team** (Codex, after the plan, before code) — adversarially attack the
   plan: wrong root cause, missed consumers, bad anchors, missing tests, fail-secure
   holes, scope creep.
3. **Implement** (Claude) — within the red-teamed plan; tests for behavior + fail paths.
4. **Ripple check** (Codex, after the diff) — independent: did it stay inside the
   surveyed frame? Re-measures the actual diff's graph impact.
5. **Verify + merge** (manual workflow policy — the Stop hook does not run it) — run
   the repo's deterministic gates (`dar verify` runs the ones configured in
   `.dar.config.sh`) + a **fresh** Claude self-audit; treat a Codex `ship` as necessary
   but not sufficient. Deterministic gates are the merge authority; no model's "looks
   good" is.

## The blast-radius gate (survey vs skip)
Diff size is a *proxy* for impact that is uncorrelated — sometimes anti-correlated —
with real blast radius. `dar probe` measures the real thing: it builds a dependency
graph (in-house pure Node — always the authority; a current graphify graph is merged
in **additively**, edges only, never replacing native resolution) and computes each
changed file's reverse-dependency fan-out + subsystem spread, plus a hot-path tripwire
(which also covers agent control planes: `prompts/`, `skills/`, `commands/`, hooks and
their entrypoint scripts).

**Skip requires positive proof of containment.** Survey fires on *any* of:
fan-out > threshold, spread > threshold, a hot-path file, an unresolved symbol, a
changed file in a language the native graph can't resolve, low overall graph
confidence, or any probe/config/graph failure (unreadable graph, bad hot-path regex,
an undiffable state). The asymmetry is deliberate: a false skip is an unbounded bug; a false
survey is a few bounded minutes. Static graphs miss dynamic dispatch / DI /
cross-language edges — which is exactly why *unresolved → survey* is load-bearing. (A
*stale* graphify graph doesn't survey-everything; it is ignored and the fresh native
graph is used.)

## Reconciliation & anti-thrash
- Disagreement → gather deterministic evidence (run the test, open the anchor), then
  escalate to the human on high-blast/security work. **Never debate to consensus** —
  multi-agent debate converges wrong; models are sycophantic and share biases.
- Caps: **1** plan-red-team cycle, **2** implement-review-fix cycles, then escalate.
  `/clear` a reviewing context after two failed corrections.

## Anti-habituation
Reviewer approval silently rises as inspection effort falls (documented
rubber-stamping). Two defenses: every `dar` Codex verdict carries a `coverage` block
(visible scrutiny), and `dar canary` can be run **on demand** — it plants a known
fail-open fault in a throwaway repo and checks the reviewer catches it. A reviewer
that misses the canary shouldn't be trusted until it passes a fresh one.

## What the evidence does and does not support
Based on the 2025-2026 research and practitioner tooling this design drew on (the
sources are cited in the project notes, not vendored here):
- **Well-supported:** external/fresh-context review beats self-review; the
  skepticism-first adversarial prompt shape; blast-radius/impact gating as a shipping
  pattern (Nx/Pants/Turborepo affected, CodeQL data-flow, code-graph tools);
  disagreement→escalate over debate; tiered escalate-on-uncertainty (ICLR 2025).
- **NOT yet proven (treat as hypotheses to calibrate):** that graph-gating beats a
  diff-size heuristic on a real defect set, and that a pre-code plan red-team is
  additive over a strong post-diff review. No controlled study isolates either.

## Calibration protocol (Phase 2 — do this on real work)
The thresholds in `config/defaults.sh` are seeds. Calibrate against this repo's own
history:
1. Run `dar probe` over the last N merged PRs that caused incidents. Did it survey
   them? Tune `DAR_FANOUT_THRESHOLD` / `DAR_SPREAD_THRESHOLD` until known-bad changes
   survey and known-trivial ones skip.
2. Confirm hot-path patterns match this repo's real danger zones.
3. Track: does the scope survey surface consumers the post-diff review would have
   missed? If not for a class of change, narrow where the survey runs.
4. Record calibration decisions here.

## How it's enforced
The plugin ships four hooks (`hooks/hooks.json`), so the gate is automatic by
default (`DAR_ENFORCE=off` disables it):
- **`Stop` hook** — the automatic engine, and it **hard-verifies**. After Claude
  responds, it runs the fast probe; a high-blast change blocks completion **until a
  `dar ripple` review returns a `ship` verdict for the current diff** — the receipt
  records the verdict and is keyed to the tracked diff + untracked file *contents*, so
  a `block`/`revise` review does not clear the gate. It does not self-satisfy, and
  changing the diff (e.g. fixing findings) forces a fresh review. If the same unshipped
  diff is blocked past a bounded cap, it stops looping (honoring `stop_hook_active`,
  staying under Claude Code's consecutive-block override), records a `blocked-unresolved`
  marker, and escalates to the human rather than silently passing. An *unmeasurable*
  state (node/probe down) can't be cleared by a receipt, so there it fails secure by
  blocking once (advisory).
- **`UserPromptSubmit` hook** — a light, once-per-session reminder to run the upstream
  gates (`dar scope`, `dar plan-redteam`) on high-blast work. Advisory only; those
  gates can't be hook-enforced (no "a plan was produced" event, especially for informal
  planning), so this + the skill's standing trigger are how they get run.
- **`PreToolUse(git commit)` hook** — surfaces the same blast-radius signal at commit
  time (advisory by default; `DAR_ENFORCE=block` refuses, `off` silences).
- **`SessionStart` hook** — bootstrap that runs each startup, with a marker so the
  heavier step (best-effort codex-plugin-cc install) happens once (also puts `dar` on
  the session PATH). It does not touch graphify.

The slash commands and the skill remain available for running the full loop
deliberately. Deterministic gates (tests/typecheck) stay the real merge authority.
