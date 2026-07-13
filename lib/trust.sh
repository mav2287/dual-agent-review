# shellcheck shell=bash
# dual-agent-review — repo trust registry.
#
# `.dar.config.sh` is executed as shell, so it may only ever run for repos the USER
# has explicitly trusted (`dar trust`). The registry lives in the plugin state dir —
# OUTSIDE any repo — so a repo cannot self-trust, and a freshly cloned/untrusted repo
# gets defaults only. `.dar.thresholds` (parsed, never executed) is also honored only
# for trusted repos, so an untrusted clone cannot raise its own thresholds either.
# DAR_NO_REPO_CONFIG=1 remains a hard override that refuses .dar.config.sh even for
# trusted repos.

# Same stable dar-owned dir as dar_state_dir — never CLAUDE_PLUGIN_DATA (a foreign
# plugin's leaked value would silently split the registry between hook and CLI).
dar_trust_file() { echo "${DAR_STATE_DIR:-${HOME}/.claude/plugins/data/dual-agent-review}/trusted-repos"; }

# dar_repo_trusted REPO — 0 iff REPO's resolved physical path is registered.
dar_repo_trusted() {
  local repo f line
  repo="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  f="$(dar_trust_file)"
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$repo" ] && return 0
  done < "$f"
  return 1
}

dar_trust_add() { # REPO
  local repo f
  repo="$(cd "$1" 2>/dev/null && pwd -P)" || { echo "dar trust: no such directory: $1" >&2; return 2; }
  f="$(dar_trust_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  if dar_repo_trusted "$repo"; then echo "already trusted: $repo"; return 0; fi
  printf '%s\n' "$repo" >> "$f" || { echo "dar trust: cannot write $f" >&2; return 2; }
  echo "trusted: $repo"
  echo "  .dar.config.sh (if present) will now be EXECUTED by the manual gates, and"
  echo "  .dar.thresholds will be honored by the automatic hooks. Review both files."
}

dar_trust_remove() { # REPO (a deleted path may be passed verbatim)
  local repo f tmp
  repo="$(cd "$1" 2>/dev/null && pwd -P)" || repo="$1"
  f="$(dar_trust_file)"
  [ -f "$f" ] || { echo "not trusted: $repo"; return 0; }
  tmp="${f}.tmp.$$"
  # grep exits 1 when nothing remains (removing the last entry) — that's success here.
  grep -Fxv "$repo" "$f" > "$tmp" || true
  mv "$tmp" "$f"
  echo "untrusted: $repo"
}

dar_trust_list() {
  local f; f="$(dar_trust_file)"
  if [ -s "$f" ]; then cat "$f"; else echo "(no trusted repos)"; fi
}
