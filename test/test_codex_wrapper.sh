#!/usr/bin/env bash
# B2 / N9 — the Codex wrapper must build argv without crashing on an empty model_opts
# array under `set -u` (the macOS Bash 3.2 default-config crash), and the doctor
# smoke test must exercise that path.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "codex wrapper (B2/N9)"

# shellcheck source=/dev/null
source "$DAR_ROOT/config/defaults.sh"
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/codex.sh"

# selftest passes with model/effort unset (the crash path)
if ( unset DAR_CODEX_MODEL DAR_CODEX_EFFORT; set -u; dar_codex_selftest ); then
  pass "selftest ok with model/effort unset"
else fail "selftest ok with model/effort unset"; fi

# argv construction: unset → no model flags; never empty
DAR_CODEX_MODEL="" DAR_CODEX_EFFORT="" dar_codex_argv /r /s "prompt"
assert_true "argv non-empty when model unset" test "${#DAR_CODEX_ARGV[@]}" -ge 6
if printf '%s\n' "${DAR_CODEX_ARGV[@]}" | grep -q -- '-s'; then
  pass "argv carries -s read-only"
else fail "argv carries -s read-only"; fi
assert_not_contains "no model flag when unset" "${DAR_CODEX_ARGV[*]}" "model="

# forced model/effort → flags present, spaces preserved
DAR_CODEX_MODEL="gpt-x" DAR_CODEX_EFFORT="high" dar_codex_argv /r /s "a b c"
assert_contains "forced model flag present" "${DAR_CODEX_ARGV[*]}" "model=gpt-x"
assert_contains "forced effort flag present" "${DAR_CODEX_ARGV[*]}" "model_reasoning_effort=high"
# last element is the prompt, spaces intact
last="${DAR_CODEX_ARGV[$(( ${#DAR_CODEX_ARGV[@]} - 1 ))]}"
assert_eq "prompt spaces preserved" "a b c" "$last"

finish
