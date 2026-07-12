# shellcheck shell=bash
# dual-agent-review — Codex invocation wrapper (Layer 1).
#
# The single choke point through which every reviewer/surveyor pass runs Codex.
# Encodes the hard-won mechanics (read-only sandbox, stdin-wedge guard, stderr
# capture, structured output) so no caller can get them wrong.

# dar_codex_run ROLE_PROMPT_FILE CONTEXT_FILE SCHEMA_FILE OUT_FILE ERR_FILE TARGET_REPO
# Runs Codex read-only against TARGET_REPO with (role prompt + context) and forces
# a JSON answer matching SCHEMA_FILE onto stdout → OUT_FILE. Returns codex's exit
# code, or 97 on a detected stdin-wedge, or 98 if codex is missing.
dar_codex_run() {
  local role="$1" ctx="$2" schema="$3" out="$4" err="$5" repo="$6"

  # DAR_CODEX_BIN is the ABSOLUTE codex path, resolved and frozen in lib/common.sh
  # BEFORE any repo config runs. Invoking it by absolute path (not `codex` or
  # `command codex`) is immune to a hostile .dar.config.sh that mutates PATH or
  # defines a `codex()`/`command()` function — the read-only sandbox can't be escaped.
  [ -n "${DAR_CODEX_BIN:-}" ] || { echo "dar: codex not found (DAR_CODEX_BIN unset)" >&2; return 98; }

  local prompt
  prompt="$(cat "$role")"$'\n\n---\n\n'"$(cat "$ctx")"

  # Model and reasoning effort are INHERITED from the user's ~/.codex/config.toml —
  # we do NOT pin them (a hardcoded model goes stale the moment codex ships a newer
  # one). They are forced ONLY if the user explicitly sets DAR_CODEX_MODEL /
  # DAR_CODEX_EFFORT. `dar doctor` flags a stale configured model (free, local).
  local model_opts=()
  [ -n "${DAR_CODEX_MODEL:-}" ] && model_opts+=(-c "model=${DAR_CODEX_MODEL}")
  [ -n "${DAR_CODEX_EFFORT:-}" ] && model_opts+=(-c "model_reasoning_effort=${DAR_CODEX_EFFORT}")

  # </dev/null is mandatory: codex exec waits forever on stdin EOF otherwise.
  # stderr MUST go to a file (never /dev/null) or a wedge is invisible.
  # -s read-only and web_search=disabled are dar POLICY (a reviewer must not mutate
  # the tree or need the web), so those are set unconditionally.
  "$DAR_CODEX_BIN" exec \
    -C "$repo" \
    -s read-only \
    "${model_opts[@]}" \
    -c web_search="${DAR_CODEX_WEBSEARCH:-disabled}" \
    --output-schema "$schema" \
    "$prompt" \
    </dev/null >"$out" 2>"$err"
  local rc=$?

  # </dev/null (above) is what actually prevents the stdin hang. Codex prints
  # "Reading additional input from stdin..." as a NORMAL startup banner even when
  # given /dev/null, so it is NOT a wedge signal — do not treat it as one. A real
  # hang is handled by the hook/CLI timeout, not by string-matching the banner.
  return $rc
}
