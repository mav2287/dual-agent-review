#!/usr/bin/env node
// dual-agent-review — precommit-gate helper: parse the PreToolUse hook's stdin JSON
// and answer (a) is this Bash command possibly a `git commit`, (b) which directory
// does the commit actually target (`git -C <path>`, leading `cd <path> && ...`),
// (c) which session is it (for the baseline lookup).
//
// Output: one line, \x1f-separated (NULs don't survive command substitution, and
// paths can contain spaces/tabs):  hasCommit \x1f ambiguous \x1f cdTarget \x1f cTarget \x1f sessionId
// EMPTY output means "could not parse" — the caller must then run the gate
// conservatively against the session project (never skip).
//
// "ambiguous" is set when the command changes directory in a way we saw but could
// not capture (a cd beyond the leading one, or a -C whose operand we couldn't
// parse): measuring would risk measuring the WRONG repo, so the caller must say
// "not measured" instead of guessing.

import { readFileSync } from "node:fs";

let d;
try { d = JSON.parse(readFileSync(0, "utf8")); } catch { process.exit(0); }
const cmd = String((d.tool_input && d.tool_input.command) || "");
const sid = String(d.session_id || "");
if (!cmd) process.exit(0);

// Same loose containment the gate always used (fail-open filter, narrowed later).
const hasCommit = cmd.includes("git") && cmd.includes("commit");

const q = (m) => (m ? (m[2] ?? m[3] ?? m[4] ?? "") : "");
const mC = cmd.match(/\bgit\s+(?:[^|;&]*?\s)?-C[= ]\s*("([^"]+)"|'([^']+)'|(\S+))/);
const mCd = cmd.match(/^\s*cd\s+("([^"]+)"|'([^']+)'|(\S+))\s*(?:&&|;)/);
const cTarget = q(mC);
const cdTarget = q(mCd);

const cdCount = (cmd.match(/(?:^|[;&|]\s*)cd\s/g) || []).length;
const ambiguous =
  (cdCount > (cdTarget ? 1 : 0)) ||
  (/\bgit\s[^|;&]*-C[= ]/.test(cmd) && !cTarget);

process.stdout.write(
  [hasCommit ? "1" : "0", ambiguous ? "1" : "0", cdTarget, cTarget, sid].join("\x1f")
);
