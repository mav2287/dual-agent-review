#!/usr/bin/env node
// dual-agent-review — blast-radius probe (Layer 1).
//
// Decides survey-vs-skip by MEASURING a change's real impact, never by diff size.
// Computes the reverse-dependency (consumer) set of every changed file and combines
// it with a hot-path tripwire and fail-secure staleness/resolution/confidence arms.
//
// Graph backend, in order of preference:
//   1. graphify's graph.json if present (richer, optional accelerator);
//   2. otherwise a pure-Node dependency graph built here (lib/graph.mjs) — the
//      always-available default that keeps this toolkit STANDALONE (Node + git only).
//
// Contract: the ONLY way to get {survey:false} is positive proof of containment —
// every changed file resolved in a trustworthy graph, low fan-out, single subsystem,
// no hot-path hit. Any error, unknown symbol, stale/low-confidence graph → survey.
//
// Usage: node blast-radius.mjs --repo <path> [--diff-base <ref>] [--files a,b,c] [--pretty]

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { buildConsumerGraph, isCode, isWellResolved, isInert } from "./graph.mjs";

const args = process.argv.slice(2);
const opt = (name, def = null) => { const i = args.indexOf(`--${name}`); return i >= 0 && args[i + 1] ? args[i + 1] : def; };
const has = (name) => args.includes(`--${name}`);

const repo = opt("repo", process.cwd());
const diffBase = opt("diff-base", "HEAD");
const filesArg = opt("files");
const pretty = has("pretty");

// A malformed hot-path regex must fail SECURE (survey), never crash the probe to
// a silent exit that the commit hook reads as "clear".
let HOTPATHS = [], configError = null;
// Numeric thresholds must be FINITE. Number("abc") and Number(".") are NaN, and every
// NaN comparison is false — which would silently disable the threshold/confidence
// tripwires (fail-open). A non-finite value keeps the safe default AND records a
// config error, which itself forces a survey.
const num = (name, def) => {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return def;
  const v = Number(raw);
  if (!Number.isFinite(v)) { if (!configError) configError = `bad ${name}: ${String(raw).slice(0, 40)}`; return def; }
  return v;
};
const FANOUT_THRESHOLD = num("DAR_FANOUT_THRESHOLD", 150);
const SPREAD_THRESHOLD = num("DAR_SPREAD_THRESHOLD", 3);
const BFS_DEPTH = num("DAR_BFS_DEPTH", 3);
const MIN_CONFIDENCE = num("DAR_MIN_CONFIDENCE", 0.4);
try { HOTPATHS = (process.env.DAR_HOTPATHS || "").split("\n").map((s) => s.trim()).filter(Boolean).map((p) => new RegExp(p)); }
catch (e) { configError = `bad DAR_HOTPATHS regex: ${String(e).slice(0, 120)}`; }

// Repository-tunable non-code classification (finding #6). DAR_OPAQUE_EXTRA forces a
// file to be treated as an opaque control surface (survey); DAR_INERT_EXTRA lets a repo
// positively classify its own inert files. A malformed regex fails SECURE (opaque wins).
const compileList = (v) => {
  try { return (v || "").split("\n").map((s) => s.trim()).filter(Boolean).map((p) => new RegExp(p)); }
  catch (e) { if (!configError) configError = `bad classification regex: ${String(e).slice(0, 120)}`; return []; }
};
const INERT_EXTRA = compileList(process.env.DAR_INERT_EXTRA);
const OPAQUE_EXTRA = compileList(process.env.DAR_OPAQUE_EXTRA);
// A non-code file is inert only with POSITIVE proof: OPAQUE_EXTRA always wins (opaque),
// then the built-in inert allowlist or a repo's INERT_EXTRA may clear it.
const fileIsInert = (file) => !OPAQUE_EXTRA.some((re) => re.test(file)) &&
  (isInert(file) || INERT_EXTRA.some((re) => re.test(file)));

function emit(survey, reasons, signals = {}) {
  const out = { survey, reasons, signals };
  process.stdout.write(pretty ? JSON.stringify(out, null, 2) + "\n" : JSON.stringify(out) + "\n");
  process.exit(0);
}
const surveyBecause = (reason, signals = {}) => emit(true, [reason], signals);

function git(cmdArgs) {
  return execFileSync("git", ["-C", repo, ...cmdArgs], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
}

let headCommit = null;
try { headCommit = git(["rev-parse", "HEAD"]); } catch { /* no commits */ }

// ── changed files ────────────────────────────────────────────────────────────
let changedFiles = [];
if (filesArg) {
  changedFiles = filesArg.split(",").map((s) => s.trim()).filter(Boolean);
} else {
  try {
    const parts = [git(["diff", "--name-only", diffBase]), git(["diff", "--name-only", "--cached"]),
      git(["ls-files", "--others", "--exclude-standard"]), git(["diff", "--name-only"])];
    changedFiles = [...new Set(parts.join("\n").split("\n").map((s) => s.trim()).filter(Boolean))];
  } catch { surveyBecause("cannot-compute-diff"); }
}
if (changedFiles.length === 0) emit(false, ["no-changes"], { changedFiles: [] });

const hotHits = changedFiles.filter((f) => HOTPATHS.some((re) => re.test(f)));

// Hook ENTRYPOINT scripts are control planes: nothing imports/sources them, so their
// graph fan-out is 0 and they would look "contained" — but changing one changes
// enforcement behavior itself. Discover them from the plugin's hooks.json and the
// repo's .claude/settings so a change to any registered hook target forces a survey
// (this is a real config→script dependency edge, resolved positively rather than
// assumed inert). See finding: operational hook targets must not false-skip.
function collectHookTargets(root) {
  const out = new Set();
  const sources = [
    join(root, "hooks", "hooks.json"),
    join(root, ".claude", "settings.json"),
    join(root, ".claude", "settings.local.json"),
  ];
  for (const p of sources) {
    if (!existsSync(p)) continue;
    let cfg; try { cfg = JSON.parse(readFileSync(p, "utf8")); } catch { continue; }
    for (const groups of Object.values(cfg.hooks || {})) {
      for (const grp of groups || []) {
        for (const h of grp.hooks || []) {
          const parts = [h.command, ...(Array.isArray(h.args) ? h.args : [])].filter((x) => typeof x === "string");
          for (const raw of parts) {
            const norm = raw
              .replace(/\$\{?CLAUDE_PLUGIN_ROOT\}?\/?/g, "")
              .replace(/\$\{?CLAUDE_PROJECT_DIR\}?\/?/g, "")
              .replace(/^\.\//, "");
            if (norm.includes("/") && /\.(sh|bash|mjs|cjs|js|py|rb)$/.test(norm)) out.add(norm);
          }
        }
      }
    }
  }
  return out;
}
const hookTargets = collectHookTargets(repo);
const hookHits = changedFiles.filter((f) => hookTargets.has(f));

// ── build the consumer graph ─────────────────────────────────────────────────
// Subsystem = the file's directory (top ≤2 path segments), NEVER the filename — a
// shallow path like `lib/x.sh` must not make each consumer its own subsystem (#15).
const subsystem = (file) => { const p = file.split("/"); return p.length <= 1 ? "." : p.slice(0, Math.min(2, p.length - 1)).join("/"); };

// The NATIVE graph is ALWAYS built and is the sole authority for whether a changed
// file is resolved (finding #4). graphify, when fresh, may only ADD edges — and only
// between files native already tracks. It can never mark a file resolved or lower the
// measured fan-out. Merging graphify `source_file`s into the file set would NOT be
// monotonic (an untracked/graphify-only path could flip to resolved-zero-fanout), so
// we never do that; `built_at_commit === HEAD` proves a commit id, not a clean tree.
let consumersOf, files, builtAtCommit, confidence = 1, perFile = new Map();
try {
  ({ consumersOf, files, builtAtCommit, confidence, perFile } = buildConsumerGraph(repo));
} catch (e) { surveyBecause("graph-build-failed", { changedFiles, hotPaths: hotHits, error: String(e).slice(0, 160) }); }

let backend = "native", graphifyFellBack = false, graphifyEdgesMerged = 0, graphifyEdgesDropped = 0;
const graphPath = join(repo, "graphify-out", "graph.json");
let graphifyGraph = null;
if (existsSync(graphPath)) {
  try { graphifyGraph = JSON.parse(readFileSync(graphPath, "utf8")); }
  catch (e) { surveyBecause("graph-unreadable", { changedFiles, hotPaths: hotHits, error: String(e).slice(0, 160) }); }
}
if (graphifyGraph && graphifyGraph.built_at_commit && headCommit && graphifyGraph.built_at_commit === headCommit) {
  backend = "native+graphify";
  const fileOf = new Map();
  for (const n of graphifyGraph.nodes || []) { if (n.source_file) fileOf.set(n.id, n.source_file); }
  for (const l of graphifyGraph.links || []) {
    const cf = fileOf.get(l.source), tf = fileOf.get(l.target);
    if (!cf || !tf || cf === tf) continue;
    // Edge-only, native-authoritative: drop any edge touching a path native does not
    // track. This keeps the merge monotonic (fan-out can only grow) and fail-secure.
    if (!files.has(cf) || !files.has(tf)) { graphifyEdgesDropped++; continue; }
    if (!consumersOf.has(tf)) consumersOf.set(tf, new Set());
    if (!consumersOf.get(tf).has(cf)) { consumersOf.get(tf).add(cf); graphifyEdgesMerged++; }
  }
} else if (graphifyGraph !== null) {
  graphifyFellBack = true; // present but not current → native only
}

// ── resolve changed files + reverse-BFS the consumer set (file level) ────────
const resolved = [], unresolved = [];
const consumerFiles = new Set(), consumerSubsystems = new Set();
for (const file of changedFiles) {
  if (!files.has(file)) { unresolved.push({ file, why: "not-in-graph" }); continue; }
  // A changed file counts as resolved ONLY with positive proof of its blast radius:
  //   • well-resolved code  → we can graph its consumers; or
  //   • genuinely inert      → a doc/asset with no cross-file blast radius.
  // Everything else — code in a language we can't graph, or an opaque control surface
  // (manifests, schemas, CI, lockfiles) — is UNRESOLVED and forces a survey. File
  // presence in the repo is NOT proof of containment (#4, #6). Applies to EVERY
  // backend (graphify never exempts a file from this).
  if (isCode(file)) {
    if (!isWellResolved(file)) { unresolved.push({ file, why: "unsupported-language" }); continue; }
  } else if (!fileIsInert(file)) {
    unresolved.push({ file, why: "opaque-control-file" }); continue;
  }
  resolved.push(file);
  const seen = new Set([file]);
  let frontier = [file];
  for (let d = 0; d < BFS_DEPTH && frontier.length; d++) {
    const next = [];
    for (const f of frontier) for (const c of consumersOf.get(f) || []) {
      if (seen.has(c)) continue;
      seen.add(c); next.push(c); consumerFiles.add(c); consumerSubsystems.add(subsystem(c));
    }
    frontier = next;
  }
}

// ── decide ────────────────────────────────────────────────────────────────────
const fanout = consumerFiles.size, spread = consumerSubsystems.size;

// Confidence: the repo-wide score can hide poor resolution right around the change.
// Compute a LOCAL score over the changed files + their consumers and combine with the
// global one via MIN, so the local view can only LOWER confidence (⇒ more surveys),
// never raise it above the global floor (finding #16 — avoids survivor bias weakening
// the gate). Global stays the fallback when the neighbourhood attempted nothing.
let localAttempted = 0, localResolved = 0;
for (const f of new Set([...changedFiles, ...consumerFiles])) {
  const pf = perFile.get(f); if (pf) { localAttempted += pf.attempted; localResolved += pf.resolved; }
}
const localConfidence = localAttempted === 0 ? 1 : localResolved / localAttempted;
const effectiveConfidence = Math.min(confidence, localConfidence);

const reasons = [];
if (configError) reasons.push(`${configError} (fail-secure)`);
if (hotHits.length) reasons.push(`hot-path: ${hotHits.join(", ")}`);
if (hookHits.length) reasons.push(`hook-entrypoint (control surface): ${hookHits.join(", ")}`);
if (effectiveConfidence < MIN_CONFIDENCE)
  reasons.push(`low-graph-confidence ${effectiveConfidence.toFixed(2)} < ${MIN_CONFIDENCE} (resolver could not link enough imports near the change; failing safe)`);
if (unresolved.length) reasons.push(`unresolved (fail-secure): ${unresolved.map((u) => `${u.file}[${u.why}]`).join(", ")}`);
if (fanout > FANOUT_THRESHOLD) reasons.push(`fan-out ${fanout} > ${FANOUT_THRESHOLD}`);
if (spread > SPREAD_THRESHOLD) reasons.push(`subsystem spread ${spread} > ${SPREAD_THRESHOLD}`);

const survey = reasons.length > 0;
if (!survey) reasons.push(`contained: fan-out ${fanout} ≤ ${FANOUT_THRESHOLD}, spread ${spread} ≤ ${SPREAD_THRESHOLD}, all files resolved, no hot-path`);

emit(survey, reasons, {
  backend, changedFiles, resolved, unresolved, fanout, spread,
  confidence: Number(effectiveConfidence.toFixed(3)),
  globalConfidence: Number(confidence.toFixed(3)),
  localConfidence: Number(localConfidence.toFixed(3)),
  hotPaths: hotHits, hookEntrypoints: hookHits, subsystemsTouched: [...consumerSubsystems].sort(),
  builtAtCommit, headCommit, graphifyFellBack, graphifyEdgesMerged, graphifyEdgesDropped,
});
