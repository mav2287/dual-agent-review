---
description: "Gate 4 — post-diff ripple check: did the change escape its surveyed frame?"
---

After implementing, run the independent ripple check.

1. Run: `dar ripple --repo "$(pwd)" --diff-base <base-ref> --scope-map <scope-map.json>`
2. If `scope_conformance.respected_scope_map` is **false** or `out_of_frame_touches`
   is non-empty, the change left its frame — investigate that first.
3. Fix `block`/`revise` findings and re-run at most twice.
4. A `ship` verdict is necessary but **not** sufficient: still run the repo's
   deterministic gates (lint, typecheck, tests, mutation, migration-lint, i18n) and a
   fresh Claude self-audit before merging.

Report the verdict, scope conformance, and any findings.

$ARGUMENTS
