#!/usr/bin/env bash
# Gate 4 — post-diff ripple check. Independent Codex pass over the finished diff:
# did it stay inside the surveyed blast radius, and did anything escape the frame?
# Re-runs the probe on the ACTUAL diff and compares graph impact to the scope map.
#
# Usage: dar ripple --repo <path> [--diff-base <ref>] [--scope-map <file>]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

REPO="" DIFF_BASE="HEAD" SCOPE_MAP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --diff-base) DIFF_BASE="$2"; shift 2;;
    --scope-map) SCOPE_MAP="$2"; shift 2;;
    *) echo "dar ripple: unknown arg $1" >&2; exit 2;;
  esac
done
[[ -n "$REPO" ]] || { echo "dar ripple: --repo required" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
dar_load_repo_config "$REPO"

RUN="$(dar_new_run ripple)"

# Re-measure impact on the ACTUAL diff (not the intended change).
dar_probe "$REPO" --diff-base "$DIFF_BASE" --pretty > "${RUN}/actual-impact.json"

CTX="${RUN}/context.md"
{
  echo "## The diff under review"
  git -C "$REPO" diff "$DIFF_BASE" | head -c 200000
  echo
  echo "## Actual measured impact of this diff"
  cat "${RUN}/actual-impact.json"
  echo
  if [[ -n "$SCOPE_MAP" && -f "$SCOPE_MAP" ]]; then
    echo "## Original scope map (what was anticipated)"
    cat "$SCOPE_MAP"
    echo
    echo "Compare the actual impact and the diff against this map. Files touched"
    echo "that the map did not anticipate go in scope_conformance.out_of_frame_touches"
    echo "(and, where a real risk, a finding with category out-of-frame)."
  fi
} > "$CTX"

OUT="${RUN}/review.json"; ERR="${RUN}/codex.err"
echo "── ripple check (codex, read-only) … ──"
if dar_codex_run "${DAR_HOME}/prompts/ripple.md" "$CTX" "${DAR_HOME}/schemas/review.schema.json" "$OUT" "$ERR" "$REPO"; then
  VERDICT="$(dar_json verdict "$OUT")"
  CONFORM="$(dar_json scope_conformance.respected_scope_map "$OUT")"
  echo "→ verdict: ${VERDICT}   scope-respected: ${CONFORM}   (findings: $OUT)"
  dar_json findings "$OUT" | node -e 'JSON.parse(require("fs").readFileSync(0)).forEach(f=>console.log(`  [${f.severity}/${f.category}] ${f.claim}`))' 2>/dev/null || true
  [[ "$VERDICT" == "ship" ]] || exit 3
else
  rc=$?; echo "dar ripple: codex failed (rc=$rc); see $ERR" >&2; exit "$rc"
fi
