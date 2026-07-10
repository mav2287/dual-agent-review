# shellcheck shell=bash
# Example per-repo override — copy to <your-repo>/.dar.config.sh and edit.
# Sourced AFTER config/defaults.sh, so anything set here wins.

# Add your app's danger zones to the generic hot-path set. Changing any file
# matching these always surveys, regardless of graph fan-out. Use YOUR repo's
# real high-cost surfaces (authorization, tenancy, payments, data access, etc.).
DAR_HOTPATHS="${DAR_HOTPATHS}
(^|/)lib/auth/
(^|/)payments?/
(^|/)permissions?/
(^|/)core/db/"

# Tune the triage thresholds to your repo. Larger, more interconnected codebases
# usually want a higher fan-out bar; calibrate against your own incident history
# (see docs/dual-agent-workflow.md — the gate is asymmetric: a false skip is an
# unbounded bug, a false survey is a few minutes, so bias toward surveying).
DAR_FANOUT_THRESHOLD=250
DAR_SPREAD_THRESHOLD=5

# The native resolver is precise for JS/TS and shell; for repos in other
# languages it fails safe by surveying more. Lower this only after calibration.
# DAR_MIN_CONFIDENCE=0.4
