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
import { buildConsumerGraph, isCode, isWellResolved } from "./graph.mjs";

const args = process.argv.slice(2);
const opt = (name, def = null) => { const i = args.indexOf(`--${name}`); return i >= 0 && args[i + 1] ? args[i + 1] : def; };
const has = (name) => args.includes(`--${name}`);

const repo = opt("repo", process.cwd());
const diffBase = opt("diff-base", "HEAD");
const filesArg = opt("files");
const pretty = has("pretty");

const FANOUT_THRESHOLD = Number(process.env.DAR_FANOUT_THRESHOLD || 150);
const SPREAD_THRESHOLD = Number(process.env.DAR_SPREAD_THRESHOLD || 3);
const BFS_DEPTH = Number(process.env.DAR_BFS_DEPTH || 3);
const MIN_CONFIDENCE = Number(process.env.DAR_MIN_CONFIDENCE || 0.4);
// A malformed hot-path regex must fail SECURE (survey), never crash the probe to
// a silent exit that the commit hook reads as "clear".
let HOTPATHS = [], configError = null;
try { HOTPATHS = (process.env.DAR_HOTPATHS || "").split("\n").map((s) => s.trim()).filter(Boolean).map((p) => new RegExp(p)); }
catch (e) { configError = `bad DAR_HOTPATHS regex: ${String(e).slice(0, 120)}`; }

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

// ── build the consumer graph (graphify if present, else native) ──────────────
const subsystem = (file) => file.split("/").slice(0, 3).join("/");
let backend, consumersOf, files, builtAtCommit, confidence = 1;

// graphify is used ONLY when its graph is current (built at HEAD). A stale
// graphify graph is not "fail-safe by surveying everything" — it falls back to the
// always-fresh native builder, which is accurate. This removes any window where a
// lagging accelerator could report a wrong (low) fan-out.
const graphPath = join(repo, "graphify-out", "graph.json");
let graphifyGraph = null;
if (existsSync(graphPath)) {
  try { graphifyGraph = JSON.parse(readFileSync(graphPath, "utf8")); }
  catch (e) { surveyBecause("graph-unreadable", { changedFiles, hotPaths: hotHits, error: String(e).slice(0, 160) }); }
}
let graphifyFellBack = false;
if (graphifyGraph && graphifyGraph.built_at_commit && headCommit && graphifyGraph.built_at_commit === headCommit) {
  backend = "graphify";
  builtAtCommit = graphifyGraph.built_at_commit;
  const fileOf = new Map();
  files = new Set();
  for (const n of graphifyGraph.nodes || []) { if (n.source_file) { fileOf.set(n.id, n.source_file); files.add(n.source_file); } }
  consumersOf = new Map(); // targetFile -> Set(consumerFile)
  for (const l of graphifyGraph.links || []) {
    const cf = fileOf.get(l.source), tf = fileOf.get(l.target);
    if (!cf || !tf || cf === tf) continue;
    if (!consumersOf.has(tf)) consumersOf.set(tf, new Set());
    consumersOf.get(tf).add(cf);
  }
} else {
  backend = "native";
  graphifyFellBack = graphifyGraph !== null; // present but not current
  try {
    ({ consumersOf, files, builtAtCommit, confidence } = buildConsumerGraph(repo));
  } catch (e) { surveyBecause("graph-build-failed", { changedFiles, hotPaths: hotHits, error: String(e).slice(0, 160) }); }
}

// ── resolve changed files + reverse-BFS the consumer set (file level) ────────
const resolved = [], unresolved = [];
const consumerFiles = new Set(), consumerSubsystems = new Set();
for (const file of changedFiles) {
  if (!files.has(file)) { unresolved.push({ file, why: "not-in-graph" }); continue; }
  // Native backend: a code file in a language we can't reliably graph has an
  // unknown blast radius — its missing edges must not read as containment.
  if (backend === "native" && isCode(file) && !isWellResolved(file)) { unresolved.push({ file, why: "unsupported-language" }); continue; }
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
const reasons = [];
if (configError) reasons.push(`${configError} (fail-secure)`);
if (hotHits.length) reasons.push(`hot-path: ${hotHits.join(", ")}`);
if (backend === "native" && confidence < MIN_CONFIDENCE)
  reasons.push(`low-graph-confidence ${confidence.toFixed(2)} < ${MIN_CONFIDENCE} (native resolver could not link enough imports; failing safe)`);
if (unresolved.length) reasons.push(`unresolved (fail-secure): ${unresolved.map((u) => `${u.file}[${u.why}]`).join(", ")}`);
if (fanout > FANOUT_THRESHOLD) reasons.push(`fan-out ${fanout} > ${FANOUT_THRESHOLD}`);
if (spread > SPREAD_THRESHOLD) reasons.push(`subsystem spread ${spread} > ${SPREAD_THRESHOLD}`);

const survey = reasons.length > 0;
if (!survey) reasons.push(`contained: fan-out ${fanout} ≤ ${FANOUT_THRESHOLD}, spread ${spread} ≤ ${SPREAD_THRESHOLD}, all files resolved, no hot-path`);

emit(survey, reasons, {
  backend, changedFiles, resolved, unresolved, fanout, spread,
  confidence: Number(confidence.toFixed(3)),
  hotPaths: hotHits, subsystemsTouched: [...consumerSubsystems].sort(),
  builtAtCommit, headCommit, graphifyFellBack,
});
