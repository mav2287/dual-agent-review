# shellcheck shell=bash
# Dependency-free test helpers (Node + git only, matching the toolkit's ethos).
set -uo pipefail

DAR_ROOT="${DAR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DAR_ROOT DAR_HOME="$DAR_ROOT"

_TESTS=0 _FAILS=0
pass() { _TESTS=$((_TESTS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { _TESTS=$((_TESTS + 1)); _FAILS=$((_FAILS + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

assert_eq() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
assert_true() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label" "command failed: $*"; fi; }
assert_false() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$label" "expected non-zero exit: $*"; else pass "$label"; fi; }
assert_contains() { case "$2" in *"$3"*) pass "$1";; *) fail "$1" "[$2] lacks [$3]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1" "[$2] unexpectedly has [$3]";; *) pass "$1";; esac; }

finish() {
  echo
  if [ "$_FAILS" -eq 0 ]; then echo "OK — $_TESTS assertions passed"; exit 0
  else echo "FAIL — $_FAILS of $_TESTS assertions failed"; exit 1; fi
}

# new_repo — create a throwaway git repo, echo its path.
new_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t >/dev/null 2>&1
  git -C "$d" config user.name t >/dev/null 2>&1
  git -C "$d" config commit.gpgsign false >/dev/null 2>&1
  echo "$d"
}
git_commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" -c commit.gpgsign=false commit -q -m "${2:-c}" --allow-empty; }

# probe_field FILES REPO FIELD — run the blast-radius probe over --files and read a
# top-level JSON field (survey / reasons / signals.fanout …) via node.
probe_field() {
  local files="$1" repo="$2" field="$3"
  node "$DAR_ROOT/lib/blast-radius.mjs" --repo "$repo" --files "$files" \
    | node -e 'const d=JSON.parse(require("fs").readFileSync(0));const v=process.argv[1].split(".").reduce((a,k)=>a==null?a:a[k],d);process.stdout.write(typeof v==="object"?JSON.stringify(v):String(v))' "$field"
}
