---
description: "Run the repo's deterministic merge gates (typecheck, lint, tests) — the real merge authority"
---

Run the repo's own deterministic gates. dar's automatic gates enforce that an
independent review ran and shipped; they do **not** run your tests/typecheck/lint —
those are the real merge authority and live in the repo.

1. Run: `dar verify --repo "$(pwd)"`
2. This runs the commands configured in the repo's `.dar.config.sh`
   (`DAR_TYPECHECK_CMD`, `DAR_LINT_CMD`, `DAR_TEST_CMD`). If none are configured, it
   prints how to set them and exits 0.
3. Fix any failing gate before merging. A `ship` ripple verdict is necessary but **not**
   sufficient — a clean `dar verify` (plus a fresh self-audit) is what makes a change
   safe to merge.

Report which gates ran and their pass/fail results.

$ARGUMENTS
