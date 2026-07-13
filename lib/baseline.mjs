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
// unchanged: same size AND same content hash as its baseline record (mtime is stored
// for observability but NEVER used as proof — same-size same-mtime content swaps are
// real). Both-unreadable counts as unchanged so root-owned junk stays inert for as
// long as it stays unreadable. Hashing is size-gated: a size mismatch skips the read.
//
// DAR_EXCLUDE (newline-separated regexes, set only via a TRUSTED repo's
// .dar.thresholds or the user's env) filters noise paths out of the delta; a bad
// pattern is ignored (keeping the files — conservative).
//
// Usage:
//   node baseline.mjs capture     --repo <path> --out <file>
//   node baseline.mjs delta       --repo <path> --baseline <file>
//   node baseline.mjs fingerprint --repo <path> --baseline <file>

import { readFileSync, writeFileSync, lstatSync, readlinkSync, renameSync } from "node:fs";
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

// [size, mtimeMs] — [-1,-1] for unreadable/absent. Size is the cheap first-pass
// discriminator; CONTENT HASH is the proof (sig alone is never trusted as unchanged).
// lstat, never stat: a symlink is its own object — following it would let a repo
// symlink read (and hash) arbitrary host files.
function sig(path) {
  try { const s = lstatSync(join(repo, path)); return [s.size, Math.floor(s.mtimeMs)]; }
  catch { return [-1, -1]; }
}
// sha1 of content, or null when unreadable. null==null compares as unchanged: an
// unreadable file that STAYS unreadable cannot be proven changed, and treating it as
// perpetually-changed would re-wedge every repo with root-owned artifacts.
// A symlink hashes its TARGET PATH STRING, never the pointed-to content — hashing
// through the link would both leak host-file state into the fingerprint and let
// out-of-repo edits churn it.
function contentHash(path) {
  const p = join(repo, path);
  try {
    if (lstatSync(p).isSymbolicLink()) return createHash("sha1").update("LINK\0" + readlinkSync(p)).digest("hex");
    return createHash("sha1").update(readFileSync(p)).digest("hex");
  } catch { return null; }
}

function headCommit() {
  try { return git(["rev-parse", "HEAD"]).toString("utf8").trim(); } catch { return "NONE"; }
}
// The empty tree: the diff base for sessions that started before the first commit,
// so tracked content created by a mid-session initial commit is still fingerprinted.
function emptyTree() {
  return execFileSync("git", ["-C", repo, "hash-object", "-t", "tree", "/dev/null"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
}

if (mode === "capture") {
  const out = opt("out"); if (!out) die("capture: --out required");
  let all;
  try { ({ all } = enumerateCurrent()); } catch (e) { die(`enumeration failed: ${String(e).slice(0, 120)}`); }
  const files = {};
  for (const f of all) files[f] = [...sig(f), contentHash(f)];
  const doc = JSON.stringify({ v: 2, head: headCommit(), files });
  try { writeFileSync(out + ".tmp", doc, { mode: 0o600 }); renameSync(out + ".tmp", out); }
  catch (e) { die(`cannot write baseline: ${String(e).slice(0, 120)}`); }
  process.stdout.write(JSON.stringify({ ok: true, files: all.length }) + "\n");
  process.exit(0);
}

// ── delta / fingerprint share the comparison ─────────────────────────────────
const baselinePath = opt("baseline"); if (!baselinePath) die(`${mode}: --baseline required`);
let base;
try { base = JSON.parse(readFileSync(baselinePath, "utf8")); } catch { die("baseline-unreadable"); }
if (!base || base.v !== 2 || typeof base.files !== "object" || !base.head) die("baseline-malformed");

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
  if (!Array.isArray(b) || b.length < 3) { deltaSet.add(f); continue; }   // appeared after baseline
  const [s] = sig(f);
  if (s !== b[0]) { deltaSet.add(f); continue; }        // size differs → changed (no read needed)
  if (contentHash(f) !== b[2]) deltaSet.add(f);         // proof by content, never by mtime
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
// DELETIONS of baseline files. A baseline file absent from the current enumeration
// is either (a) tracked and reverted/committed — it still exists on disk, skip — or
// (b) GONE from disk: deleting an untracked file (a fixture, an env file, a hook)
// is a real session change and must gate; tracked deletions already ride `git diff`.
const curAll = new Set(cur.all);
const deletedSet = new Set();
for (const f of Object.keys(base.files)) {
  if (curAll.has(f)) continue;
  let gone = false;
  try { lstatSync(join(repo, f)); } catch { gone = true; }
  if (gone) { deletedSet.add(f); deltaSet.add(f); }
}

// DAR_EXCLUDE — trusted-repo noise filter. A bad regex is skipped (files KEPT).
const excludes = [];
for (const p of (process.env.DAR_EXCLUDE || "").split("\n").map((s) => s.trim()).filter(Boolean)) {
  try { excludes.push(new RegExp(p)); } catch { /* keep files */ }
}
const delta = [...deltaSet].filter((f) => !excludes.some((re) => re.test(f))).sort();
const untrackedSet = new Set(cur.untracked);
const untrackedDelta = delta.filter((f) => untrackedSet.has(f));
const deletedUntracked = delta.filter((f) => deletedSet.has(f));
const unsafe = delta.some((f) => f.includes(",") || f.includes("\n"));

if (mode === "delta") {
  process.stdout.write(JSON.stringify({ ok: true, baseHead: base.head, delta, untrackedDelta, deletedUntracked, unsafe }) + "\n");
  process.exit(0);
}

if (mode === "fingerprint") {
  // Baseline-relative fingerprint: the tracked diff vs the baseline HEAD (worktree vs
  // base covers both committed-since-base and uncommitted edits; --binary so binary
  // content changes register) + session-new/changed untracked file CONTENTS, framed
  // exactly like lib/fingerprint.sh's legacy stream (length-framed, NUL-separated) so
  // distinct file sets can't collide. A baseline captured before the repo's first
  // commit diffs against the EMPTY TREE once commits exist — tracked content created
  // by that first commit must keep moving the fingerprint.
  const h = createHash("sha1");
  h.update("DIFF\0");
  let diffBase = base.head;
  if (diffBase === "NONE" && headCommit() !== "NONE") {
    try { diffBase = emptyTree(); } catch { die("cannot-resolve-empty-tree"); }
  }
  if (diffBase !== "NONE") {
    try { h.update(git(["diff", "--binary", diffBase])); } catch { die("cannot-diff-base"); }
  }
  h.update("\0");
  for (const f of untrackedDelta) {
    let content;
    try {
      const p = join(repo, f);
      content = lstatSync(p).isSymbolicLink() ? Buffer.from("LINK\0" + readlinkSync(p)) : readFileSync(p);
    } catch { content = Buffer.alloc(0); }
    h.update(`F namelen=${Buffer.byteLength(f)} bytes=${content.length}\0`);
    h.update(f); h.update("\0");
    h.update(content); h.update("\0");
  }
  // Deletions are part of the state: removing an untracked file must invalidate a
  // prior receipt just like editing one.
  for (const f of deletedUntracked) {
    h.update(`D namelen=${Buffer.byteLength(f)}\0`);
    h.update(f); h.update("\0");
  }
  process.stdout.write(h.digest("hex").slice(0, 40));
  process.exit(0);
}

die(`unknown mode: ${mode}`);
