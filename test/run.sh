#!/usr/bin/env bash
# dual-agent-review test suite — standalone (Node + git only). Runs static checks, Node
# unit tests, and the bash behavior tests. Exercised in CI on macOS (stock Bash 3.2) and
# Linux (modern bash). Usage: bash test/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DAR_ROOT="$ROOT"
cd "$ROOT" || exit 2
fails=0
section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "bash: version"
bash --version | head -1

section "static: bash -n (syntax)"
SH_FILES=$(ls lib/*.sh scripts/*.sh config/*.sh test/*.sh examples/*.sh 2>/dev/null) || true
for f in $SH_FILES bin/dar install.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f"; then echo "  ok  $f"; else echo "  FAIL $f"; fails=$((fails + 1)); fi
done

section "static: node --check"
for f in lib/*.mjs; do
  if node --check "$f"; then echo "  ok  $f"; else echo "  FAIL $f"; fails=$((fails + 1)); fi
done

section "static: JSON well-formed"
for f in .claude-plugin/*.json hooks/*.json schemas/*.json; do
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$f"; then echo "  ok  $f"; else echo "  FAIL $f"; fails=$((fails + 1)); fi
done

section "node unit tests"
if node --test test/*.test.mjs; then echo "  node tests passed"; else echo "  node tests FAILED"; fails=$((fails + 1)); fi

section "bash behavior tests"
for t in test/test_*.sh; do
  printf '\n--- %s ---\n' "$t"
  if bash "$t"; then :; else fails=$((fails + 1)); fi
done

echo
if [ "$fails" -eq 0 ]; then
  echo -e "\033[32mALL GREEN\033[0m"; exit 0
else
  echo -e "\033[31m${fails} check/suite(s) failed\033[0m"; exit 1
fi
