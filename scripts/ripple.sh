#!/usr/bin/env bash
# Gate 4 — post-diff ripple check. Independent Codex pass over the finished diff:
# did it stay inside the surveyed blast radius, and did anything escape the frame?
# Re-runs the probe on the ACTUAL diff and compares graph impact to the scope map.
#
# Usage: dar ripple --repo <path> [--baseline <file> | --diff-base <ref>] [--scope-map <file>]
#
# --baseline is what the automatic Stop gate hands out: the review then covers the
# SESSION's changes (diff vs the baseline HEAD + session-new untracked files) and the
# receipt is written with the SESSION fingerprint — the only thing that clears the
# gate. --diff-base remains for deliberate manual reviews without a baseline.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=/dev/null
source "${DAR_HOME}/lib/fingerprint.sh"

REPO="" DIFF_BASE="" SCOPE_MAP="" BASELINE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --diff-base) DIFF_BASE="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --scope-map) SCOPE_MAP="$2"; shift 2;;
    *) echo "dar ripple: unknown arg $1" >&2; exit 2;;
  esac
done
[[ -n "$REPO" ]] || { echo "dar ripple: --repo required" >&2; exit 2; }
if [[ -n "$BASELINE" && -n "$DIFF_BASE" ]]; then
  echo "dar ripple: --baseline and --diff-base are mutually exclusive (the baseline defines the diff base)" >&2; exit 2
fi
REPO="$(cd "$REPO" && pwd)"
dar_load_repo_config "$REPO"

RUN="$(dar_new_run ripple)"

# ── frame the change: session baseline, or an explicit/default diff base ─────
FILES_CSV=""
DELTA_PATHS=""       # NUL-separated tracked+untracked delta pathspec file (session mode)
UNTRACKED_LIST=""    # NUL-separated untracked files whose CONTENT the receipt covers
if [[ -n "$BASELINE" ]]; then
  [[ -f "$BASELINE" ]] || { echo "dar ripple: baseline not found: $BASELINE" >&2; exit 2; }
  deltaj="$(node "${DAR_HOME}/lib/baseline.mjs" delta --repo "$REPO" --baseline "$BASELINE")" \
    || { echo "dar ripple: cannot compute the session delta — failing secure, no review run." >&2; exit 2; }
  read -r d_ok d_head d_unsafe < <(
    printf '%s' "$deltaj" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.ok} ${d.baseHead||"?"} ${d.unsafe||false}`)}catch{process.stdout.write("false ? false")}'
  )
  [[ "$d_ok" == "true" ]] || { echo "dar ripple: baseline unusable ($(printf '%s' "$deltaj" | head -c 120)) — failing secure, no review run." >&2; exit 2; }
  if [[ "$d_head" == "NONE" ]]; then
    DIFF_BASE="$(git -C "$REPO" hash-object -t tree /dev/null)"   # empty tree: review everything
  else
    DIFF_BASE="$d_head"
  fi
  if [[ "$d_unsafe" != "true" ]]; then
    FILES_CSV="$(printf '%s' "$deltaj" | node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(0)).delta.join(","))}catch{}')"
  fi
  # Path lists for context building — NUL-separated so odd filenames survive.
  RUN_PRE="$(mktemp -d)"
  DELTA_PATHS="${RUN_PRE}/delta-paths"; UNTRACKED_LIST="${RUN_PRE}/untracked-list"
  printf '%s' "$deltaj" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(d.delta.join("\0"))' > "$DELTA_PATHS" || DELTA_PATHS=""
  printf '%s' "$deltaj" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(d.untrackedDelta.join("\0"))' > "$UNTRACKED_LIST" || UNTRACKED_LIST=""
else
  DIFF_BASE="${DIFF_BASE:-HEAD}"
fi

# Re-measure impact on the ACTUAL change (session delta when we have one, so
# pre-existing worktree noise doesn't drown the measurement).
if [[ -n "$FILES_CSV" ]]; then
  dar_probe "$REPO" --files "$FILES_CSV" --pretty > "${RUN}/actual-impact.json"
else
  dar_probe "$REPO" --diff-base "$DIFF_BASE" --pretty > "${RUN}/actual-impact.json"
fi

# Capture the diff to a FILE first, then slice it. Piping `git diff | head -c` sends
# SIGPIPE to git when head stops early; under the inherited `pipefail` that returned
# 141 and aborted the whole context build before Codex ran (finding #5). Reading from
# a file has no pipe, so no SIGPIPE. A git FAILURE (e.g. an invalid --diff-base) must
# NOT be swallowed — reviewing an empty diff as if the tree were clean is fail-open.
FULL_DIFF="${RUN}/full.diff"
# In session mode, scope the tracked diff to the DELTA paths: pre-session dirty files
# are not under review (they'd dilute the reviewer and skew scope-conformance). If
# pathspec scoping fails for any reason, fall back to the FULL diff — reviewing more
# than needed is safe; reviewing less is not.
if [[ -s "${DELTA_PATHS:-}" ]] && git -C "$REPO" diff "$DIFF_BASE" --pathspec-from-file="$DELTA_PATHS" --pathspec-file-nul > "$FULL_DIFF" 2>"${RUN}/diff.err"; then
  :
elif ! git -C "$REPO" diff "$DIFF_BASE" > "$FULL_DIFF" 2>"${RUN}/diff.err"; then
  echo "dar ripple: could not compute diff against '${DIFF_BASE}' (see ${RUN}/diff.err) — failing secure, no review run." >&2
  exit 2
fi
DIFF_BYTES=$(wc -c < "$FULL_DIFF" | tr -d ' ')

# The receipt's fingerprint covers untracked-file CONTENTS — so the reviewer must
# actually SEE them ('git diff' never shows untracked files; without this, a brand-new
# implementation file could earn a ship receipt sight-unseen). Session mode reviews
# the session's new untracked files; legacy mode reviews all untracked files (matching
# what each mode's fingerprint covers). Bounded: 40 KB/file, 150 KB total; binary
# files are named with a size placeholder.
emit_untracked_section() { # NUL-separated list on stdin
  local budget=150000 per=40000 f sz
  echo "## New files in this change (untracked — not visible in the diff above)"
  while IFS= read -r -d '' f; do
    [ -f "${REPO}/${f}" ] || continue
    sz=$(wc -c < "${REPO}/${f}" 2>/dev/null | tr -d ' '); [ -n "$sz" ] || sz=0
    printf '\n### %s (%s bytes)\n' "$f" "$sz"
    if LC_ALL=C grep -q "$(printf '\0')" "${REPO}/${f}" 2>/dev/null; then
      echo '[binary content omitted]'
      continue
    fi
    if [ "$budget" -le 0 ]; then echo '[content omitted: context budget exhausted]'; continue; fi
    local take=$per; [ "$take" -gt "$budget" ] && take=$budget
    echo '```'
    head -c "$take" "${REPO}/${f}" 2>/dev/null
    echo; echo '```'
    [ "$sz" -gt "$take" ] && printf '[truncated to %s of %s bytes]\n' "$take" "$sz"
    budget=$(( budget - (sz < take ? sz : take) ))
  done
}

CTX="${RUN}/context.md"
{
  echo "## The diff under review"
  head -c 200000 "$FULL_DIFF"
  [ "$DIFF_BYTES" -gt 200000 ] && printf '\n\n[diff truncated to 200000 of %s bytes for the review context]\n' "$DIFF_BYTES"
  echo
  if [[ -n "$BASELINE" ]]; then
    [[ -s "${UNTRACKED_LIST:-}" ]] && emit_untracked_section < "$UNTRACKED_LIST"
  else
    git -C "$REPO" ls-files -z --others --exclude-standard 2>/dev/null | emit_untracked_section
  fi
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
  # Record the receipt WITH the verdict, keyed to the fingerprint the Stop gate will
  # recompute (session fingerprint when a baseline framed this review, else legacy).
  # The gate releases only on `ship`; a block/revise receipt matches but does NOT
  # clear (#7). Fixing findings changes the fingerprint → the next review starts fresh.
  if [[ -n "$BASELINE" ]]; then
    FP="$(dar_session_fingerprint "$REPO" "$BASELINE")"
    dar_write_receipt_fp "$REPO" "$FP" "$VERDICT"
  else
    dar_write_receipt "$REPO" "$VERDICT"
  fi
  [[ "$VERDICT" == "ship" ]] || exit 3
else
  rc=$?; echo "dar ripple: codex failed (rc=$rc); see $ERR" >&2; exit "$rc"
fi
