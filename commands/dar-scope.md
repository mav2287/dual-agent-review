---
description: "Gate 1 — survey the blast radius before planning a change (Codex, read-only)"
---

Before planning the change described below, run the blast-radius scope survey.

1. Run: `dar scope --repo "$(pwd)" --task "<one-line description of the intended change>" --diff-base <base-ref>`
   (use `--files a,b,c` instead of `--diff-base` if the change isn't staged yet).
2. If it prints **SKIP**, the change is provably contained — plan normally.
3. If it prints a **scope map**, read `plan_constraints`, `consumers`, and
   `invariants_in_range`, and treat them as hard requirements for your plan. Note the
   scope-map path — you'll pass it to `/dar-plan-redteam` and `/dar-ripple`.

Report the verdict and the constraints; do not start coding yet.

$ARGUMENTS
