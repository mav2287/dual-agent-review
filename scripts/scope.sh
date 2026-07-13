#!/usr/bin/env bash
# Gate 1 — scope survey. Blast-radius probe decides survey-vs-skip; on survey,
# Codex maps the terrain the integrator must plan within (given the measured
# fan-out and subsystems so it starts from the blast radius, not from zero).
#
# Usage: dar scope --repo <path> --task "<what you intend to change>" \
#                  [--diff-base <ref> | --files a,b,c] [--force]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

REPO="" TASK="" FORCE=0; PROBE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --task) TASK="$2"; shift 2;;
    --diff-base) PROBE_ARGS+=(--diff-base "$2"); shift 2;;
    --files) PROBE_ARGS+=(--files "$2"); shift 2;;
    --force) FORCE=1; shift;;
    *) echo "dar scope: unknown arg $1" >&2; exit 2;;
  esac
done
[[ -n "$REPO" ]] || { echo "dar scope: --repo required" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
dar_load_repo_config "$REPO"

RUN="$(dar_new_run scope)"
PROBE="${RUN}/probe.json"
# Empty-array expansion is unbound-variable-safe on Bash 3.2 via the ${a[@]+…} guard
# (PROBE_ARGS is empty when neither --diff-base nor --files is passed).
dar_probe "$REPO" "${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"}" --pretty > "$PROBE"

SURVEY="$(dar_json survey "$PROBE")"
CHANGED="$(dar_json signals.changedFiles "$PROBE")"
echo "── blast-radius probe ──"
dar_json reasons "$PROBE" | node -e 'JSON.parse(require("fs").readFileSync(0)).forEach(r=>console.log("  •",r))'

# SKIP is only valid when a REAL, non-empty change was measured and proven contained.
# `dar scope` is the PRE-PLAN gate: before you write code there is usually no diff yet,
# and an empty working tree is NOT proof the intended task is contained. So on a clean
# branch (changedFiles == []) we survey the task instead of skipping (fail-secure).
if [[ "$SURVEY" != "true" && "$CHANGED" != "[]" && "$FORCE" -ne 1 ]]; then
  echo "→ SKIP: measured change is provably contained. No survey needed."
  echo "  (probe: $PROBE)"
  exit 0
fi
[[ "$CHANGED" == "[]" ]] && echo "  • no diff yet (pre-plan) — surveying the intended task, not skipping"

[[ -n "$TASK" ]] || { echo "dar scope: --task required when surveying" >&2; exit 2; }

# Give Codex the task and, when there IS a diff, the measured blast radius. On a clean
# pre-plan branch (no diff) there is nothing to measure, so ask Codex to survey the
# intended task's likely blast radius from the repository itself.
CTX="${RUN}/context.md"
if [[ "$CHANGED" == "[]" ]]; then
  {
    echo "## Intended change (task)"
    echo "$TASK"
    echo
    echo "## No diff yet — pre-plan survey"
    echo "There is no working diff to measure. Survey this task's likely blast radius"
    echo "from the repository itself: which modules and files a change like this would"
    echo "touch, their consumers, the invariants and cross-subsystem edges it endangers,"
    echo "and the hot-path/control surfaces (auth, migrations, config, hooks) in range."
  } > "$CTX"
else
  {
    echo "## Intended change (task)"
    echo "$TASK"
    echo
    echo "## Measured blast radius (from the dependency graph)"
    echo "Changed files: $(dar_json signals.changedFiles "$PROBE")"
    echo "Consumer fan-out: $(dar_json signals.fanout "$PROBE") files across $(dar_json signals.spread "$PROBE") subsystems."
    echo "Subsystems in range:"
    dar_json signals.subsystemsTouched "$PROBE" | node -e 'JSON.parse(require("fs").readFileSync(0)).forEach(s=>console.log("  -",s))' 2>/dev/null || true
    echo
    echo "Use these fan-out and subsystem figures as your starting point — expand from"
    echo "the changed files into their consumers and reason about what the change endangers."
  } > "$CTX"
fi

OUT="${RUN}/scope-map.json"; ERR="${RUN}/codex.err"
echo "── surveying (codex, read-only) … ──"
if dar_codex_run "${DAR_HOME}/prompts/scope.md" "$CTX" "${DAR_HOME}/schemas/scope.schema.json" "$OUT" "$ERR" "$REPO"; then
  echo "→ scope map: $OUT"
  echo "  plan_constraints:"
  dar_json plan_constraints "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0)).forEach(c=>console.log("    •",c))' 2>/dev/null || true
else
  rc=$?; echo "dar scope: codex failed (rc=$rc); see $ERR" >&2; exit "$rc"
fi
