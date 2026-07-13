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

# 7) The CLI round-trip.
out="$(bash "$DAR_ROOT/bin/dar" untrust --repo "$R")"
assert_contains "dar untrust" "$out" "untrusted:"
out="$(bash "$DAR_ROOT/bin/dar" trust --repo "$R")"
assert_contains "dar trust" "$out" "trusted:"
out="$(bash "$DAR_ROOT/bin/dar" trust --list)"
assert_contains "dar trust --list shows the repo" "$out" "$(cd "$R" && pwd -P)"

finish
