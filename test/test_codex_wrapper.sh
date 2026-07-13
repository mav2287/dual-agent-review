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

# argv construction: unset → no model flags; never empty; prompt NOT in argv (stdin).
DAR_CODEX_MODEL="" DAR_CODEX_EFFORT="" dar_codex_argv /r /s
assert_true "argv non-empty when model unset" test "${#DAR_CODEX_ARGV[@]}" -ge 6
if printf '%s\n' "${DAR_CODEX_ARGV[@]}" | grep -q -- '-s'; then
  pass "argv carries -s read-only"
else fail "argv carries -s read-only"; fi
assert_not_contains "no model flag when unset" "${DAR_CODEX_ARGV[*]}" "model="
last="${DAR_CODEX_ARGV[$(( ${#DAR_CODEX_ARGV[@]} - 1 ))]}"
assert_eq "argv ends with - (prompt via stdin)" "-" "$last"

# forced model/effort → flags present
DAR_CODEX_MODEL="gpt-x" DAR_CODEX_EFFORT="high" dar_codex_argv /r /s
assert_contains "forced model flag present" "${DAR_CODEX_ARGV[*]}" "model=gpt-x"
assert_contains "forced effort flag present" "${DAR_CODEX_ARGV[*]}" "model_reasoning_effort=high"

# Prompt is delivered on stdin and can be LARGE (>128 KB) without E2BIG. A stub that
# echoes stdin length proves the whole prompt reaches codex regardless of size.
STUB="$(mktemp)"; printf '#!/usr/bin/env bash\nwc -c\n' > "$STUB"; chmod +x "$STUB"
role="$(mktemp)"; ctx="$(mktemp)"; out="$(mktemp)"; err="$(mktemp)"
echo "role" > "$role"
node -e 'process.stdout.write("Z".repeat(300000))' > "$ctx"   # ~300 KB context
DAR_CODEX_BIN="$STUB" dar_codex_run "$role" "$ctx" /s "$out" "$err" /tmp
got="$(tr -d ' ' < "$out")"
assert_true "large prompt (>128KB) delivered via stdin, no E2BIG" test "$got" -gt 300000
rm -f "$STUB" "$role" "$ctx" "$out" "$err"

finish
