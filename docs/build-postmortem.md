# Build postmortem — traps hit while building dar, kept so they aren't re-hit

Hard-won, each one cost real debugging time. Verified against the current code as of
2026-07-13; file references are to this repo.

## Codex integration

- **`codex exec --output-schema` uses OpenAI STRICT json_schema.** EVERY property
  must be listed in `required`; optional fields must be nullable
  (`"type": ["string","null"]`), not omitted. Schemas that listed only some keys in
  `required` produced `invalid_json_schema` 400s on EVERY real call — while every
  `JSON.parse`-based unit check passed. **Lesson: always do one live end-to-end run;
  static checks cannot catch API-contract failures.** (schemas/*.json)
- **Prompt over argv hits Linux `MAX_ARG_STRLEN` (~128 KB) → E2BIG.** macOS has no
  per-arg cap, so only Linux CI caught it. Codex reads the prompt from stdin when
  argv ends with `-`; pipe it (lib/codex.sh). stdin has no size limit and is
  portable.
- **`</dev/null` is what prevents the historical stdin hang** when codex runs
  non-interactively — superseded here by the deliberate stdin-prompt protocol. The
  `"Reading additional input from stdin..."` banner is NORMAL startup output, not a
  wedge signal; a real hang is handled by timeouts, never by string-matching the
  banner.
- **Invoke codex by a FROZEN ABSOLUTE path resolved BEFORE repo config runs.**
  `command -v` can return a function/alias/relative name, and a repo's
  `.dar.config.sh` could define `command(){ }` or mutate PATH to shadow the binary
  and escape the read-only sandbox. Validate `/*` + `-x`, then `readonly`
  (lib/common.sh). Re-source the canonical codex wrapper AFTER repo config for the
  same reason.
- **Inherit the reviewer model, don't pin it.** A hardcoded model goes stale the
  moment codex ships a newer one; pass `-c model=` only when the user forces it
  (config/defaults.sh). `dar doctor` flags a stale configured model locally by
  reading `~/.codex/models_cache.json` — no API call.

## Shell + graph engineering

- **tsconfig path aliases need a STRING-AWARE JSONC parser.** A naive
  comment-stripping regex mangles `"@/*": ["./*"]`, aliases come out empty, import
  resolution collapses (observed: 99% → ~14% resolved). (lib/graph.mjs)
- **`export` every config var the Node probe reads.** A child `node` process sees
  none of the shell's unexported variables — the hot-path tripwire silently became
  EMPTY (fail-open) until exported. (config/defaults.sh)
- **No here-docs in hook-context shell.** A read-only / no-TMPDIR environment makes
  `<<EOF` fail and can silently leave a config list empty; use plain multi-line
  single-quoted assignments.
- **Shell `source` edges need a `.sh`-anywhere regex + shebang detection** for
  extensionless scripts (bin/dar); `\S+` breaks on
  `source "$(dirname …)/x.sh"`.
- **Command substitution strips NUL bytes.** Multi-field output crossing a
  `$(...)` boundary needs a different separator (dar uses `\x1f`); NUL-framing only
  works inside pipes/files. (scripts/precommit-gate.sh, lib/parse-commit-cmd.mjs)
- **`.mjs` files have no `require`.** A `try { require("fs") } catch` swallows the
  ReferenceError and the script "succeeds" with empty output — which downstream
  code then misreads. Import from `node:fs`, and never let a parse helper's empty
  output be indistinguishable from a real empty result.

## Fail-secure gate design (found by dogfooding — the tool reviewed itself)

- **The gate's own live review flagged its Stop hook as fail-OPEN** (measurement
  failure → allow); fixed to block on unmeasurable state. A later Codex red-team
  found the release marker was written ON BLOCK (satisfiable by ignoring findings);
  fixed to a receipt written only by a COMPLETED review, keyed to the exact state
  fingerprint, released only on a `ship` verdict.
- **Gating "the dirty worktree" is the wrong frame for a user-scoped plugin.** A
  repo with thousands of pre-existing untracked build artifacts trips (and re-hashes)
  everything on every Stop. The frame must be THE SESSION'S OWN WORK: a SessionStart
  baseline + delta, including commits made during the session so committing can't
  launder a change past the gate. (lib/baseline.mjs, scripts/stop-gate.sh)
- **`dar canary` exists because a reviewer can rot silently** — it plants a known
  fail-open hole in a throwaway repo and checks the reviewer still names it.

## Claude Code plugin mechanics

- **Cross-marketplace plugin `dependencies` are fragile.** They need
  `allowCrossMarketplaceDependenciesOn` + the user having added that marketplace,
  and an unresolved hard dependency DISABLES your plugin. Bootstrap best-effort
  installs the codex plugin via the `claude` CLI instead (hooks can't run slash
  commands; the CLI works from a hook). (scripts/bootstrap.sh)
- **`/reload-plugins` is not a new session.** SessionStart(startup) hooks don't
  re-run, so anything they provide (PATH entries) is absent until a fresh session —
  gate messages must reference absolute paths, and a stable `~/.local/bin/dar`
  symlink covers the rest.
- **Hooks can't invoke slash commands.** A Stop hook that wants a review run must
  route through a CLI (`dar ripple`) and verify a receipt; it cannot call
  `/codex:adversarial-review` itself.

## Publishing a public repo from an agent session

- Scrub the TREE and the HISTORY and the AUTHOR/COMMITTER identity: `--amend`
  ignores `GIT_AUTHOR_*` without `--author=`; use the GitHub noreply identity, and
  strip session-URL/Co-Authored-By trailers before pushing.
- After a force-push, old SHAs stay briefly reachable on GitHub by direct ref until
  GC; a guaranteed scrub means delete+recreate (needs the `delete_repo` token
  scope). Accepted here as a residual for non-secret identity metadata.
- Keep run artifacts (scope maps, target-repo diffs) OUTSIDE the tool's repo
  (`~/.local/state/dual-agent-review/runs`) so target-repo review material can never
  be committed into the public tool.
