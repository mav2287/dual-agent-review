#!/usr/bin/env bash
# Trust model + .dar.thresholds — repo-controlled config is inert until the USER
# trusts the repo; the thresholds file is parsed (never executed), whitelisted,
# and can never override the user's own environment.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "trust registry + thresholds calibration"

export CLAUDE_PLUGIN_DATA; CLAUDE_PLUGIN_DATA="$(mktemp -d)"
R="$(new_repo)"; trap 'rm -rf "$R" "$CLAUDE_PLUGIN_DATA"' EXIT

# A hostile-ish thresholds file: whitelisted keys, a forbidden key (DAR_ENFORCE),
# an unknown key, a shell-injection-shaped value, and a strengthening pattern.
cat > "$R/.dar.thresholds" <<'EOF'
# comment
DAR_FANOUT_THRESHOLD=9999
DAR_ENFORCE=off
BOGUS_KEY=1
DAR_MAX_DELTA_FILES=7
DAR_MIN_CONFIDENCE=evil; rm -rf /
DAR_HOTPATHS_EXTRA=(^|/)mydanger/
EOF

load() { # ENV... -- prints the probe of interest
  bash -c '
    source "$0/lib/trust.sh"; source "$0/lib/thresholds.sh"; source "$0/config/defaults.sh"
    dar_load_thresholds "$1" 2>/dev/null
    echo "$DAR_FANOUT_THRESHOLD|$DAR_MAX_DELTA_FILES|${DAR_ENFORCE:-unset}|${BOGUS_KEY:-unset}|$DAR_MIN_CONFIDENCE"
  ' "$DAR_ROOT" "$R"
}

# 1) Untrusted repo → the file is ignored entirely.
assert_eq "untrusted → all defaults" "150|500|unset|unset|0.4" "$(load)"

# 2) Trust the repo → whitelisted keys apply; DAR_ENFORCE/unknown/malformed ignored.
bash -c 'source "$0/lib/trust.sh"; dar_trust_add "$1" >/dev/null' "$DAR_ROOT" "$R"
assert_eq "trusted → whitelist applies, junk inert" "9999|7|unset|unset|0.4" "$(load)"

# 3) Strengthening patterns always fold in.
hp="$(bash -c 'source "$0/lib/trust.sh"; source "$0/lib/thresholds.sh"; source "$0/config/defaults.sh"; dar_load_thresholds "$1" 2>/dev/null; printf "%s" "$DAR_HOTPATHS"' "$DAR_ROOT" "$R")"
assert_contains "HOTPATHS_EXTRA appended" "$hp" "mydanger"

# 4) The user's environment beats the repo file.
env_val="$(DAR_FANOUT_THRESHOLD=42 bash -c 'source "$0/lib/trust.sh"; source "$0/lib/thresholds.sh"; source "$0/config/defaults.sh"; dar_load_thresholds "$1" 2>/dev/null; echo "$DAR_FANOUT_THRESHOLD"' "$DAR_ROOT" "$R")"
assert_eq "user env beats repo file" "42" "$env_val"

# 5) .dar.config.sh executes ONLY for trusted repos (manual gates path).
echo 'export PWNED=yes' > "$R/.dar.config.sh"
got="$(bash -c 'source "$0/lib/common.sh"; dar_load_repo_config "$1" 2>/dev/null; echo "${PWNED:-no}"' "$DAR_ROOT" "$R")"
assert_eq "trusted → config.sh sourced" "yes" "$got"
bash -c 'source "$0/lib/trust.sh"; dar_trust_remove "$1" >/dev/null' "$DAR_ROOT" "$R"
got="$(bash -c 'source "$0/lib/common.sh"; dar_load_repo_config "$1" 2>/dev/null; echo "${PWNED:-no}"' "$DAR_ROOT" "$R")"
assert_eq "untrusted → config.sh NOT sourced" "no" "$got"

# 6) DAR_NO_REPO_CONFIG=1 refuses config.sh even when trusted.
bash -c 'source "$0/lib/trust.sh"; dar_trust_add "$1" >/dev/null' "$DAR_ROOT" "$R"
got="$(DAR_NO_REPO_CONFIG=1 bash -c 'source "$0/lib/common.sh"; dar_load_repo_config "$1" 2>/dev/null; echo "${PWNED:-no}"' "$DAR_ROOT" "$R")"
assert_eq "DAR_NO_REPO_CONFIG=1 hard override" "no" "$got"

# 7) NaN-shaped numerics are rejected everywhere: the thresholds parser refuses a
#    digitless DAR_MIN_CONFIDENCE, and the probe treats a non-finite env value as a
#    CONFIG ERROR (survey), never as a silently-disabled tripwire.
printf 'DAR_MIN_CONFIDENCE=.\n' > "$R/.dar.thresholds"
got="$(bash -c 'source "$0/lib/trust.sh"; source "$0/lib/thresholds.sh"; source "$0/config/defaults.sh"; dar_load_thresholds "$1" 2>/dev/null; echo "$DAR_MIN_CONFIDENCE"' "$DAR_ROOT" "$R")"
assert_eq "digitless MIN_CONFIDENCE rejected by parser" "0.4" "$got"
echo x > "$R/f.txt"; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c commit.gpgsign=false commit -qm c --allow-empty
reasons="$(DAR_MIN_CONFIDENCE=abc node "$DAR_ROOT/lib/blast-radius.mjs" --repo "$R" --files f.txt | node -e 'const d=JSON.parse(require("fs").readFileSync(0));process.stdout.write(`${d.survey} ${d.reasons.join(";")}`)')"
assert_contains "probe surveys on non-finite threshold env" "$reasons" "true"
assert_contains "probe names the bad config" "$reasons" "bad DAR_MIN_CONFIDENCE"

# 8) Run artifacts are user-private (0700) — they hold complete target-repo diffs.
rd="$(bash -c 'source "$0/lib/common.sh"; dar_new_run testperm' "$DAR_ROOT")"
assert_eq "run dir is 0700" "drwx------" "$(ls -ld "$rd" | cut -c1-10)"
rm -rf "$rd"

# 9) The CLI round-trip.
out="$(bash "$DAR_ROOT/bin/dar" untrust --repo "$R")"
assert_contains "dar untrust" "$out" "untrusted:"
out="$(bash "$DAR_ROOT/bin/dar" trust --repo "$R")"
assert_contains "dar trust" "$out" "trusted:"
out="$(bash "$DAR_ROOT/bin/dar" trust --list)"
assert_contains "dar trust --list shows the repo" "$out" "$(cd "$R" && pwd -P)"

finish
