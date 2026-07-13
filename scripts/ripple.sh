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
  # `|| true`: read returns 1 at EOF-without-newline even when it filled the vars,
  # and common.sh's `set -e` would otherwise kill the script here. A genuinely
  # empty read leaves d_ok != true → the fail-secure arm below.
  read -r d_ok d_head d_unsafe < <(
    printf '%s' "$deltaj" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.ok} ${d.baseHead||"?"} ${d.unsafe||false}`)}catch{process.stdout.write("false ? false")}'
  ) || true
  d_ok="${d_ok:-false}"; d_head="${d_head:-?}"; d_unsafe="${d_unsafe:-false}"
  [[ "$d_ok" == "true" ]] || { echo "dar ripple: baseline unusable ($(printf '%s' "$deltaj" | head -c 120)) — failing secure, no review run." >&2; exit 2; }
  if [[ "$d_head" == "NONE" ]]; then
    DIFF_BASE="$(git -C "$REPO" hash-object -t tree /dev/null)"   # empty tree: review everything
  else
    DIFF_BASE="$d_head"
  fi
  if [[ "$d_unsafe" != "true" ]]; then
    FILES_CSV="$(printf '%s' "$deltaj" | node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(0)).delta.join(","))}catch{}')"
  fi
  # Path lists for context building — NUL-separated so odd filenames survive. ONE
  # node call writes both lists AND reports the expected count: if the reviewer
  # cannot be shown the untracked contents the receipt would cover, there is NO
  # review (a receipt for content the reviewer never saw is fail-open).
  RUN_PRE="$(mktemp -d)"
  DELTA_PATHS="${RUN_PRE}/delta-paths"; UNTRACKED_LIST="${RUN_PRE}/untracked-list"
  d_un="$(printf '%s' "$deltaj" | node -e '
    try {
      const fs = require("fs");
      const d = JSON.parse(fs.readFileSync(0));
      // NUL-TERMINATE every record (not join): `read -d ""` drops a final
      // unterminated entry, which would silently omit the last file. The context
      // list carries DELETIONS too — the reviewer must see that a file was removed.
      const ctxList = d.untrackedDelta.concat(d.deletedUntracked || []);
      fs.writeFileSync(process.argv[1], d.delta.map(f => f + "\0").join(""));
      fs.writeFileSync(process.argv[2], ctxList.map(f => f + "\0").join(""));
      process.stdout.write(String(ctxList.length));
    } catch { process.stdout.write("FAIL"); }' "$DELTA_PATHS" "$UNTRACKED_LIST" 2>/dev/null || echo FAIL)"
  if [[ "$d_un" == "FAIL" ]]; then
    echo "dar ripple: could not stage the session file lists for the review context — failing secure, no review run." >&2
    exit 2
  fi
  if [[ "$d_un" -gt 0 && ! -s "$UNTRACKED_LIST" ]]; then
    echo "dar ripple: ${d_un} untracked session file(s) exist but their list is empty — failing secure, no review run." >&2
    exit 2
  fi
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
TRUNCATED=0   # set whenever the reviewer is shown LESS than the receipt would cover
emit_untracked_section() { # NUL-separated list on stdin
  local budget="${DAR_RIPPLE_UNTRACKED_CAP:-200000}" per="${DAR_RIPPLE_FILE_CAP:-60000}" f sz raw8 txt8
  echo "## New/removed files in this change (untracked — not visible in the diff above)"
  while IFS= read -r -d '' f; do
    # Symlinks are a trust boundary: NEVER read through one (a repo symlink to
    # ~/.ssh/... would land host secrets in the review context and run artifacts).
    if [ -L "${REPO}/${f}" ]; then
      printf '\n### %s\n[symlink → %s — content not read]\n' "$f" "$(readlink "${REPO}/${f}" 2>/dev/null || echo '?')"
      continue
    fi
    if [ ! -e "${REPO}/${f}" ]; then
      printf '\n### %s\n[DELETED this session]\n' "$f"
      continue
    fi
    [ -f "${REPO}/${f}" ] || continue
    sz=$(wc -c < "${REPO}/${f}" 2>/dev/null | tr -d ' '); [ -n "$sz" ] || sz=0
    printf '\n### %s (%s bytes)\n' "$f" "$sz"
    # Binary check: a NUL cannot ride through "$(printf '\0')" (command substitution
    # strips NULs — see docs/build-postmortem.md), so compare byte counts with and
    # without NULs over the head of the file instead.
    raw8="$(head -c 8000 "${REPO}/${f}" 2>/dev/null | wc -c | tr -d ' ')"
    txt8="$(head -c 8000 "${REPO}/${f}" 2>/dev/null | LC_ALL=C tr -d '\0' | wc -c | tr -d ' ')"
    if [ "${raw8:-0}" != "${txt8:-0}" ]; then
      echo '[binary content omitted]'
      TRUNCATED=1
      continue
    fi
    if [ "$budget" -le 0 ]; then echo '[content omitted: context budget exhausted]'; TRUNCATED=1; continue; fi
    local take=$per; [ "$take" -gt "$budget" ] && take=$budget
    echo '```'
    head -c "$take" "${REPO}/${f}" 2>/dev/null
    echo; echo '```'
    if [ "$sz" -gt "$take" ]; then printf '[truncated to %s of %s bytes]\n' "$take" "$sz"; TRUNCATED=1; fi
    budget=$(( budget - (sz < take ? sz : take) ))
  done
}

DIFF_CAP="${DAR_RIPPLE_DIFF_CAP:-600000}"
CTX="${RUN}/context.md"
{
  echo "## The diff under review"
  head -c "$DIFF_CAP" "$FULL_DIFF"
  if [ "$DIFF_BYTES" -gt "$DIFF_CAP" ]; then
    printf '\n\n[diff truncated to %s of %s bytes for the review context]\n' "$DIFF_CAP" "$DIFF_BYTES"
    TRUNCATED=1
  fi
  echo
  if [[ -n "$BASELINE" ]]; then
    [[ "${d_un:-0}" -gt 0 ]] && emit_untracked_section < "$UNTRACKED_LIST"
  else
    UL="${RUN}/untracked-legacy"
    if ! git -C "$REPO" ls-files -z --others --exclude-standard > "$UL" 2>>"${RUN}/diff.err"; then
      echo "dar ripple: cannot enumerate untracked files — failing secure, no review run." >&2
      exit 2
    fi
    [ -s "$UL" ] && emit_untracked_section < "$UL"
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
  # A ship verdict over a TRUNCATED context is not a ship: the receipt's fingerprint
  # covers the FULL change, but the reviewer saw less than that. Downgrade to
  # `partial` (never releases the gate) and say what to do about it.
  if [[ "$VERDICT" == "ship" && "$TRUNCATED" == "1" ]]; then
    VERDICT="partial"
    echo "dar ripple: the reviewer approved, but the context was TRUNCATED (change larger than the review caps) — recording 'partial', which does NOT clear the gate. Split the change, raise DAR_RIPPLE_DIFF_CAP/DAR_RIPPLE_FILE_CAP/DAR_RIPPLE_UNTRACKED_CAP if your reviewer's context allows, or review the remainder manually (/codex:adversarial-review)." >&2
  fi
  # Record the receipt WITH the verdict, keyed to the fingerprint the Stop gate will
  # recompute (session fingerprint when a baseline framed this review, else legacy).
  # The gate releases only on `ship`; a block/revise/partial receipt matches but does
  # NOT clear (#7). Fixing findings changes the fingerprint → the next review starts
  # fresh.
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
