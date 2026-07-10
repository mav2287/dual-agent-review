---
description: "Run the full dual-agent review loop (scope → plan red-team → implement → ripple → verify)"
---

Invoke the **dual-agent-review** skill and run the full loop for the current task:
blast-radius scope survey → plan red-team → implement → ripple check → verify, with
the iteration caps, reconciliation, and escalation rules it defines.

Target repo is `$(pwd)`. Follow the skill's gates in order and report at each gate.

$ARGUMENTS
