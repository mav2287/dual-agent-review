# shellcheck shell=bash
# dual-agent-review — hook-safe per-repo calibration.
#
# `.dar.thresholds` is a plain KEY=VALUE file that is PARSED line-by-line — never
# sourced or eval'd — so the AUTOMATIC hooks can honor per-repo tuning without
# executing repo-controlled shell (which `.dar.config.sh` is, and which hooks
# therefore never touch). It is honored only for repos on the trust list
# (`dar trust`): an untrusted clone cannot raise its own thresholds to slip past
# the gate.
#
# Precedence: built-in defaults < .dar.thresholds (trusted) < user environment.
# config/defaults.sh records which keys IT defaulted (DAR_DEFAULTED); the file may
# only override those — a value the user set in their own environment always wins.
#
# Whitelisted keys:
#   integer:  DAR_FANOUT_THRESHOLD DAR_SPREAD_THRESHOLD DAR_BFS_DEPTH
#             DAR_MAX_STOP_BLOCKS DAR_MAX_DELTA_FILES
#   float:    DAR_MIN_CONFIDENCE
#   regex, one pattern per line, key repeatable:
#             DAR_HOTPATHS_EXTRA  (append-only: can only ADD hot paths — always applied)
#             DAR_OPAQUE_EXTRA    (append-only: can only mark MORE files opaque — always applied)
#             DAR_INERT_EXTRA DAR_EXCLUDE  (weakening: applied only when not user-env-set)
#
# DAR_ENFORCE is deliberately NOT accepted from a repo file — enforcement mode
# belongs to the user's environment, never to the repo being gated. Unknown keys
# and malformed values are ignored (the built-in value stays — fail-secure).

# dar_thr_env_overridden KEY — 0 iff the user's environment set KEY (i.e. defaults.sh
# did NOT default it). Requires defaults.sh to have been sourced first.
dar_thr_env_overridden() {
  case " ${DAR_DEFAULTED:-} " in *" $1 "*) return 1;; *) return 0;; esac
}

dar_thr_set() { # KEY VALUE — apply a file value unless the user's env already set it.
  dar_thr_env_overridden "$1" && return 0
  eval "$1=\"\$2\""
  export "${1?}"
}

dar_thr_append() { # KEY VALUE — append VALUE as a new line of KEY's pattern list.
  local cur
  cur="$(eval "printf '%s' \"\${$1:-}\"")"
  if [ -n "$cur" ]; then eval "$1=\"\${cur}
\$2\""; else eval "$1=\"\$2\""; fi
  export "${1?}"
}

# dar_load_thresholds REPO — parse REPO/.dar.thresholds if REPO is trusted.
# Call AFTER sourcing config/defaults.sh (it consumes DAR_DEFAULTED) and at most
# once per process (repeatable keys append).
dar_load_thresholds() {
  local repo="$1" f line key val
  f="${repo}/.dar.thresholds"
  [ -f "$f" ] || return 0
  if ! dar_repo_trusted "$repo"; then
    echo "dar: ${f} present but this repo is not trusted — ignoring it (run 'dar trust --repo ${repo}' after reviewing the file to enable)." >&2
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    case "$line" in *=*) ;; *) continue;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      DAR_FANOUT_THRESHOLD|DAR_SPREAD_THRESHOLD|DAR_BFS_DEPTH|DAR_MAX_STOP_BLOCKS|DAR_MAX_STOP_BLOCKS_NONSHIP|DAR_MAX_DELTA_FILES)
        case "$val" in ''|*[!0-9]*) continue;; esac
        dar_thr_set "$key" "$val";;
      DAR_MIN_CONFIDENCE)
        # Must contain a digit ("." alone becomes NaN downstream, and NaN comparisons
        # would silently disable the confidence tripwire — fail-open).
        case "$val" in ''|*[!0-9.]*|*.*.*) continue;; esac
        case "$val" in *[0-9]*) ;; *) continue;; esac
        dar_thr_set "$key" "$val";;
      DAR_HOTPATHS_EXTRA)
        # Strengthening — always honored; folds into the pattern list the probe reads.
        [ -n "$val" ] && dar_thr_append DAR_HOTPATHS "$val";;
      DAR_OPAQUE_EXTRA)
        [ -n "$val" ] && dar_thr_append DAR_OPAQUE_EXTRA "$val";;
      DAR_INERT_EXTRA|DAR_EXCLUDE)
        # Weakening — only when the user's env did not set the key itself.
        dar_thr_env_overridden "$key" && continue
        [ -n "$val" ] && dar_thr_append "$key" "$val";;
      *) continue;;
    esac
  done < "$f"
  return 0
}
