#!/usr/bin/env node
// dual-agent-review — session baseline: capture / delta / fingerprint.
//
// The Stop gate must judge THE SESSION'S OWN WORK, not whatever the worktree already
// carried when the session began — a repo with thousands of pre-existing untracked
// build artifacts would otherwise trip (and re-hash) all of them on every Stop. The
// SessionStart hook captures a baseline manifest; the gates then operate on the DELTA:
// files whose state differs from the baseline, plus everything committed since the
// baseline HEAD — so committing mid-session cannot launder a change past the gate.
//
// Fail-secure contract: an unreadable/corrupt baseline, a missing base commit, or any
// enumeration error yields {ok:false} — callers treat that as unmeasurable (block),
// never as "clean". A file is excluded from the delta only on positive proof it is
// unchanged (same size AND same mtime as its baseline record; both-unreadable counts
// as unchanged so root-owned junk stays inert as long as it stays unreadable).
//
// DAR_EXCLUDE (newline-separated regexes, set only via a TRUSTED repo's
// .dar.thresholds or the user's env) filters noise paths out of the delta; a bad
// pattern is ignored (keeping the files — conservative).
//
// Usage:
//   node baseline.mjs capture     --repo <path> --out <file>
//   node baseline.mjs delta       --repo <path> --baseline <file>
//   node baseline.mjs fingerprint --repo <path> --baseline <file>

import { readFileSync, writeFileSync, statSync, renameSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { createHash } from "node:crypto";

const args = process.argv.slice(2);
const mode = args[0];
const opt = (name) => { const i = args.indexOf(`--${name}`); return i >= 0 && args[i + 1] ? args[i + 1] : null; };
const repo = opt("repo");
const MAXBUF = 256 * 1024 * 1024;

function die(reason) {
  if (mode === "fingerprint") { process.stderr.write(reason + "\n"); process.exit(1); }
  process.stdout.write(JSON.stringify({ ok: false, reason }) + "\n"); process.exit(0);
}
if (!repo || !mode) die("usage: baseline.mjs capture|delta|fingerprint --repo <path> ...");

function git(cmdArgs, input) {
  return execFileSync("git", ["-C", repo, ...cmdArgs],
    { encoding: "buffer", maxBuffer: MAXBUF, stdio: [input === undefined ? "ignore" : "pipe", "pipe", "ignore"], input });
}
const gitLines0 = (cmdArgs) => git(cmdArgs).toString("utf8").split("\0").filter(Boolean);

// Current "changed vs HEAD" enumeration — untracked (gitignore-respecting) plus
// tracked files whose worktree or index differs from HEAD. Same set capture and
// delta compare against, so the two sides can never disagree about scope.
function enumerateCurrent() {
  const untracked = gitLines0(["ls-files", "-z", "--others", "--exclude-standard"]);
  let tracked = [];
  try { tracked = gitLines0(["diff", "--name-only", "-z", "HEAD"]); }
  catch { tracked = []; } // no commits yet → nothing tracked to diff
  return { untracked, tracked, all: [...new Set([...untracked, ...tracked])] };
}

// [size, mtimeMs] — [-1,-1] for unreadable/absent (compared, not skipped: a file that
// WAS readable and became unreadable — or vice versa — registers as a change).
function sig(path) {
  try { const s = statSync(join(repo, path)); return [s.size, Math.floor(s.mtimeMs)]; }
  catch { return [-1, -1]; }
}

function headCommit() {
  try { return git(["rev-parse", "HEAD"]).toString("utf8").trim(); } catch { return "NONE"; }
}

if (mode === "capture") {
  const out = opt("out"); if (!out) die("capture: --out required");
  let all;
  try { ({ all } = enumerateCurrent()); } catch (e) { die(`enumeration failed: ${String(e).slice(0, 120)}`); }
  const files = {};
  for (const f of all) files[f] = sig(f);
  const doc = JSON.stringify({ v: 1, head: headCommit(), files });
  try { writeFileSync(out + ".tmp", doc); renameSync(out + ".tmp", out); }
  catch (e) { die(`cannot write baseline: ${String(e).slice(0, 120)}`); }
  process.stdout.write(JSON.stringify({ ok: true, files: all.length }) + "\n");
  process.exit(0);
}

// ── delta / fingerprint share the comparison ─────────────────────────────────
const baselinePath = opt("baseline"); if (!baselinePath) die(`${mode}: --baseline required`);
let base;
try { base = JSON.parse(readFileSync(baselinePath, "utf8")); } catch { die("baseline-unreadable"); }
if (!base || base.v !== 1 || typeof base.files !== "object" || !base.head) die("baseline-malformed");

// The base commit must still exist — a gc'd/rewritten base makes the session
// unmeasurable (block), not clean.
if (base.head !== "NONE") {
  try { git(["cat-file", "-e", `${base.head}^{commit}`]); } catch { die("base-commit-missing"); }
}

let cur;
try { cur = enumerateCurrent(); } catch (e) { die(`enumeration failed: ${String(e).slice(0, 120)}`); }

const deltaSet = new Set();
for (const f of cur.all) {
  const b = base.files[f];
  if (!b) { deltaSet.add(f); continue; }              // appeared after baseline
  const [s, m] = sig(f);
  if (s !== b[0] || m !== b[1]) deltaSet.add(f);      // positive proof of change required to skip
}
// Committed since the baseline HEAD — the commit-then-Stop laundering arm.
try {
  const now = headCommit();
  if (base.head === "NONE") {
    if (now !== "NONE") for (const f of gitLines0(["ls-tree", "-r", "-z", "--name-only", "HEAD"])) deltaSet.add(f);
  } else if (now !== "NONE" && now !== base.head) {
    for (const f of gitLines0(["diff", "--name-only", "-z", base.head, "HEAD"])) deltaSet.add(f);
  }
} catch { die("cannot-compute-committed-range"); }

// DAR_EXCLUDE — trusted-repo noise filter. A bad regex is skipped (files KEPT).
const excludes = [];
for (const p of (process.env.DAR_EXCLUDE || "").split("\n").map((s) => s.trim()).filter(Boolean)) {
  try { excludes.push(new RegExp(p)); } catch { /* keep files */ }
}
const delta = [...deltaSet].filter((f) => !excludes.some((re) => re.test(f))).sort();
const untrackedSet = new Set(cur.untracked);
const untrackedDelta = delta.filter((f) => untrackedSet.has(f));
const unsafe = delta.some((f) => f.includes(",") || f.includes("\n"));

if (mode === "delta") {
  process.stdout.write(JSON.stringify({ ok: true, baseHead: base.head, delta, untrackedDelta, unsafe }) + "\n");
  process.exit(0);
}

if (mode === "fingerprint") {
  // Baseline-relative fingerprint: the tracked diff vs the baseline HEAD (worktree vs
  // base covers both committed-since-base and uncommitted edits; --binary so binary
  // content changes register) + session-new/changed untracked file CONTENTS, framed
  // exactly like lib/fingerprint.sh's legacy stream (length-framed, NUL-separated) so
  // distinct file sets can't collide.
  const h = createHash("sha1");
  h.update("DIFF\0");
  if (base.head !== "NONE") {
    try { h.update(git(["diff", "--binary", base.head])); } catch { die("cannot-diff-base"); }
  }
  h.update("\0");
  for (const f of untrackedDelta) {
    let content;
    try { content = readFileSync(join(repo, f)); } catch { content = Buffer.alloc(0); }
    h.update(`F namelen=${Buffer.byteLength(f)} bytes=${content.length}\0`);
    h.update(f); h.update("\0");
    h.update(content); h.update("\0");
  }
  process.stdout.write(h.digest("hex").slice(0, 40));
  process.exit(0);
}

die(`unknown mode: ${mode}`);
