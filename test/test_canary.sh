#!/usr/bin/env bash
# L14 — canary scoring: a true catch requires SPECIFICALLY identifying the planted
# fail-open, not a generic non-ship verdict. Uses a stub reviewer (no real Codex).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "canary scoring (L14)"

export DAR_RUNS_DIR; DAR_RUNS_DIR="$(mktemp -d)/runs"

# make_stub JSON → path to an executable that prints JSON as codex would.
make_stub() {
  local p; p="$(mktemp)"
  { echo '#!/usr/bin/env bash'; printf 'cat <<'\''JSON'\''\n%s\nJSON\n' "$1"; } > "$p"
  chmod +x "$p"; echo "$p"
}
run_canary() { DAR_CODEX_BIN="$1" bash "$DAR_ROOT/scripts/canary.sh" >/dev/null 2>&1; }

# 1) Identifies the hole AT THE PLANTED SITE + refuses → CAUGHT (exit 0).
s1="$(make_stub '{"verdict":"block","summary":"x","findings":[{"severity":"critical","category":"fail-secure-hole","claim":"canAccess catch returns true in src/access.js","evidence":"return true"}],"scope_conformance":{"respected_scope_map":true,"out_of_frame_touches":[]},"coverage":{"reviewed":"all","not_reviewed":"none"}}')"
rc=0; run_canary "$s1" || rc=$?
assert_eq "identified fault → caught (exit 0)" "0" "$rc"

# 1b) A security-category finding that does NOT reference the planted site is NOT a
#     specific catch — an unrelated security nit must not score as detection.
s1b="$(make_stub '{"verdict":"block","summary":"x","findings":[{"severity":"high","category":"security","claim":"artifacts may be world-readable","evidence":"umask"}],"scope_conformance":{"respected_scope_map":true,"out_of_frame_touches":[]},"coverage":{"reviewed":"all","not_reviewed":"none"}}')"
rc=0; run_canary "$s1b" || rc=$?
assert_eq "unrelated security finding → missed (exit 3)" "3" "$rc"

# 2) Refuses to ship but names NO fault → MISSED (exit 3), not a catch.
s2="$(make_stub '{"verdict":"revise","summary":"style only","findings":[{"severity":"low","category":"style","claim":"rename var","evidence":"nit"}],"scope_conformance":{"respected_scope_map":true,"out_of_frame_touches":[]},"coverage":{"reviewed":"all","not_reviewed":"none"}}')"
rc=0; run_canary "$s2" || rc=$?
assert_eq "refused-without-identifying → missed (exit 3)" "3" "$rc"

# 3) Ships and identifies nothing → MISSED (exit 3).
s3="$(make_stub '{"verdict":"ship","summary":"looks good","findings":[],"scope_conformance":{"respected_scope_map":true,"out_of_frame_touches":[]},"coverage":{"reviewed":"all","not_reviewed":"none"}}')"
rc=0; run_canary "$s3" || rc=$?
assert_eq "shipped the fault → missed (exit 3)" "3" "$rc"

rm -f "$s1" "$s1b" "$s2" "$s3"
finish
