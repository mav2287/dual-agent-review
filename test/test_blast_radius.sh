#!/usr/bin/env bash
# B4 / B6 / L15 / L16 — blast-radius fail-secure behavior.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
echo "blast radius (B4/B6/L15/L16)"

R="$(new_repo)"
trap 'rm -rf "$R"' EXIT
mkdir -p "$R/lib" "$R/a" "$R/b" "$R/c" "$R/d" "$R/docs"
cat > "$R/lib/util.js" <<'EOF'
export const util = 1;
EOF
# Consumers spread across 4 distinct subsystems → spread > threshold(3) → survey.
for s in a b c d; do
  printf 'import { util } from "../lib/util.js"; export const %s = util;\n' "$s" > "$R/$s/c.js"
done
cat > "$R/main.py" <<'EOF'
x = 1
EOF
echo '{"a":1}' > "$R/config.json"
echo "docs" > "$R/docs/guide.md"
echo "ignored" > "$R/.gitignore"
git_commit "$R" init

# Native resolution: a changed lib file with wide, multi-subsystem fan-out surveys.
assert_eq "wide-fanout shared code → survey"  "true"  "$(probe_field lib/util.js "$R" survey)"
fo="$(probe_field lib/util.js "$R" signals.fanout)"
assert_true "fan-out counts all consumers" test "$fo" -ge 4
sp="$(probe_field lib/util.js "$R" signals.spread)"
assert_true "spread counts distinct subsystems" test "$sp" -ge 4

# A well-resolved code file with FEW consumers is legitimately contained (not a survey).
mkdir -p "$R/leaf"; echo 'export const z = 1;' > "$R/leaf/only.js"; git_commit "$R" leaf
assert_eq "well-resolved leaf → contained" "false" "$(probe_field leaf/only.js "$R" survey)"

# B6: opaque control file (json config) → survey; inert doc → contained.
assert_eq "opaque config.json → survey"   "true"  "$(probe_field config.json "$R" survey)"
assert_contains "opaque reason names it" "$(probe_field config.json "$R" signals.unresolved)" "opaque-control-file"
assert_eq "inert docs/guide.md → contained" "false" "$(probe_field docs/guide.md "$R" survey)"
# .gitignore is a control surface, never inert.
assert_eq ".gitignore → survey"           "true"  "$(probe_field .gitignore "$R" survey)"

# unsupported-language code file → survey (can't graph its blast radius).
assert_eq "unsupported-language main.py → survey" "true" "$(probe_field main.py "$R" survey)"
assert_contains "reason=unsupported-language" "$(probe_field main.py "$R" signals.unresolved)" "unsupported-language"

# L15: subsystem excludes the filename (root file → subsystem ".", not itself).
cat > "$R/root_consumer.js" <<'EOF'
import { util } from "./lib/util.js"; export const r = util;
EOF
git_commit "$R" more
subs="$(probe_field lib/util.js "$R" signals.subsystemsTouched)"
assert_not_contains "subsystem is not the consumer filename" "$subs" "root_consumer.js"

# B4: a graphify graph that names an UNTRACKED source_file must NOT resolve it, and its
# edges to untracked paths must be dropped (native tracked-file set stays authoritative).
HEAD="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/graphify-out"
cat > "$R/graphify-out/graph.json" <<EOF
{ "built_at_commit": "$HEAD",
  "nodes": [ {"id":"n1","source_file":"lib/util.js"}, {"id":"g1","source_file":"ghost/untracked.js"} ],
  "links": [ {"source":"g1","target":"n1"} ] }
EOF
back="$(probe_field leaf/only.js "$R" signals.backend)"
assert_eq "graphify recognized as fresh" "native+graphify" "$back"
dropped="$(probe_field leaf/only.js "$R" signals.graphifyEdgesDropped)"
assert_true "edge touching untracked path dropped" test "$dropped" -ge 1
# Probing the untracked ghost file itself: graphify naming it must NOT make it resolved.
assert_eq "untracked graphify ghost → survey (not resolved)" "true" "$(probe_field ghost/untracked.js "$R" survey)"
assert_contains "ghost reason is not-in-graph" "$(probe_field ghost/untracked.js "$R" signals.unresolved)" "not-in-graph"
# And graphify never rescues a leaf into a false skip: leaf stays contained, not falsely surveyed.
assert_eq "graphify additive: leaf still contained" "false" "$(probe_field leaf/only.js "$R" survey)"

finish
