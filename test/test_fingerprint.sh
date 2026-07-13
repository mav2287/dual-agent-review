#!/usr/bin/env bash
# B7 / N8 — receipt verdict enforcement, block counter, and collision-safe fingerprint.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "fingerprint + receipts (B7/N8)"

export CLAUDE_PLUGIN_DATA; CLAUDE_PLUGIN_DATA="$(mktemp -d)"
# shellcheck source=/dev/null
source "$DAR_ROOT/lib/fingerprint.sh"

R="$(new_repo)"; trap 'rm -rf "$R" "$CLAUDE_PLUGIN_DATA"' EXIT
echo "base" > "$R/f.txt"; git_commit "$R" init
echo "change" >> "$R/f.txt"

# B7: ship clears, block/revise does not.
dar_write_receipt "$R" "block"
assert_false "block receipt does NOT clear gate" dar_receipt_matches "$R"
assert_eq "verdict readback = block" "block" "$(dar_receipt_verdict "$R")"
dar_write_receipt "$R" "ship"
assert_true "ship receipt clears gate" dar_receipt_matches "$R"

# receipt is bound to the exact diff — changing it invalidates a ship receipt.
echo "more" >> "$R/f.txt"
assert_false "ship receipt invalid after diff change" dar_receipt_matches "$R"

# block counter increments for the same diff, resets when the diff changes.
dar_write_receipt "$R" "revise"
assert_eq "block count 1" "1" "$(dar_bump_block_count "$R")"
assert_eq "block count 2" "2" "$(dar_bump_block_count "$R")"
echo "changed-again" >> "$R/f.txt"
assert_eq "counter resets on diff change" "0" "$(dar_block_count "$R")"

# N8: adversarial untracked filename (newline) — content change must flip fingerprint.
nl_name="$(printf 'odd\nname').txt"
printf 'content-A' > "$R/$nl_name"
fp1="$(dar_diff_fingerprint "$R")"
printf 'content-B' > "$R/$nl_name"
fp2="$(dar_diff_fingerprint "$R")"
assert_true "newline-name content change flips fingerprint" test "$fp1" != "$fp2"

# N8: framing prevents the `== a\nX == b\nY` collision. Two distinct untracked sets
# with the same concatenated bytes must produce different fingerprints.
R1="$(new_repo)"; R2="$(new_repo)"
printf 'X== b\nY' > "$R1/a"                 # one file 'a'
printf 'X'        > "$R2/a"; printf 'Y' > "$R2/b"   # two files 'a','b'
fpA="$(dar_diff_fingerprint "$R1")"; fpB="$(dar_diff_fingerprint "$R2")"
assert_true "distinct file sets → distinct fingerprints" test "$fpA" != "$fpB"
rm -rf "$R1" "$R2"

finish
