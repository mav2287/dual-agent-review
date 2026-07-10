---
description: "Gate 2 — Codex adversarially red-teams your written plan before any code"
---

Red-team the current plan before writing code.

1. Write your plan to a file (e.g. `plan.md`) if it isn't already.
2. Run: `dar plan-redteam --repo "$(pwd)" --plan plan.md --scope-map <scope-map.json> --issue <issue-file>`
   (`--scope-map` and `--issue` are optional but strongly improve the review).
3. For each finding, classify it explicitly: **confirmed** (fix the plan),
   **false-positive-with-evidence** (record why), **accepted-risk** (note for the
   owner), or **needs-human** (stop and ask).
4. Re-run at most once after revising. Do not loop to consensus. If `verdict` stays
   `block` on a high-blast change, escalate to the owner.

Only proceed to implementation once the verdict is `proceed` or every finding is
classified and resolved.

$ARGUMENTS
