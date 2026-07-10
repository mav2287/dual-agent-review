# Anti-habituation canary (on-demand scrutiny check)

The research is explicit: reviewer approval silently rises as inspection effort
falls (rubber-stamping). A round cap doesn't catch this. The canary does — as an
on-demand check you run when you want to confirm the reviewer is still sharp.

## What `dar canary` actually does
`scripts/canary.sh`, run on demand:

1. Creates a **throwaway git repo** (a temp dir) with a small, fail-*secure* function
   — `canAccess` denies on any error.
2. Commits that as the baseline, then plants a **single known fault**: the error path
   now returns `true` (fail-*open* — allows access on error).
3. Runs the **real review path** over that planted diff — the same `prompts/ripple.md`
   role prompt and `schemas/review.schema.json` Codex uses for a normal ripple check.
4. Checks the reviewer's output: a healthy reviewer raises a `fail-secure-hole` /
   `security` finding (or refuses to `ship`); a habituated one misses it.
5. Reports **caught** (exit 0) or **MISSED** (exit 3), and deletes the throwaway repo.

It touches nothing in your real repos, and it is not scheduled — there is no periodic
mode. Run it whenever you want to sanity-check the reviewer.

## Outcomes
- **Caught** → the reviewer flagged the planted fault; it passed this check.
- **MISSED** → the reviewer did not flag a deliberately planted fail-open bug. Don't
  trust its verdicts until it passes a fresh canary: sharpen the prompt, raise the
  Codex effort, or hand the review to a human.

The planted fault (a fail-open error path) is a single fixture embedded in
`scripts/canary.sh`. Broadening it to a rotating catalogue of fault types is possible
future work, not current behavior.
