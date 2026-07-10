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
5. **Verify + merge** (manual workflow policy — there's no `dar verify` gate) — run
   the repo's deterministic gates + a **fresh** Claude self-audit; treat a Codex
   `ship` as necessary but not sufficient. Deterministic gates are the merge
   authority; no model's "looks good" is.

## The blast-radius gate (survey vs skip)
Diff size is a *proxy* for impact that is uncorrelated — sometimes anti-correlated —
with real blast radius. `dar probe` measures the real thing: it builds a dependency
graph (in-house pure Node by default, or graphify's graph when that is present and
current) and computes each changed file's reverse-dependency fan-out + subsystem
spread, plus a hot-path tripwire.

**Skip requires positive proof of containment.** Survey fires on *any* of:
fan-out > threshold, spread > threshold, a hot-path file, an unresolved symbol, a
changed file in a language the native graph can't resolve, low overall graph
confidence, or any probe/config/graph failure (unreadable graph, bad hot-path regex,
an undiffable state). The asymmetry is deliberate: a false skip is an unbounded bug; a false
survey is a few bounded minutes. Static graphs miss dynamic dispatch / DI /
cross-language edges — which is exactly why *unresolved → survey* is load-bearing. (A
*stale* graphify graph doesn't survey-everything; it falls back to the fresh native
graph.)

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
The plugin ships three hooks (`hooks/hooks.json`), so the gate is automatic by
default (`DAR_ENFORCE=off` disables it):
- **`Stop` hook** — the automatic engine. After Claude responds, it runs the fast
  probe; a high-blast (or unmeasurable) change blocks completion and makes Claude run
  the adversarial review before finishing. Fail-secure: if the change can't be
  measured (node/probe unavailable) it blocks rather than allowing. Blocks once per
  distinct change-state (no re-nagging) and honors `stop_hook_active`.
- **`PreToolUse(git commit)` hook** — surfaces the same signal at commit time
  (advisory by default; `DAR_ENFORCE=block` makes it refuse, `off` silences it).
- **`SessionStart` hook** — bootstrap that runs each startup, with marker files so the
  heavier steps happen once per user/project (PATH, best-effort codex-plugin-cc,
  graphify if present).

The slash commands and the skill remain available for running the full loop
deliberately. Deterministic gates (tests/typecheck) stay the real merge authority.
