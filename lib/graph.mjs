// dual-agent-review — native dependency-graph builder (pure Node, no external deps).
//
// Builds a file-level consumer graph from a repo using only Node stdlib + `git`.
// This is what makes the toolkit STANDALONE: no graphify, no Python, no npm
// packages. graphify's richer graph is preferred if present; this is the default.
//
// Output: { consumersOf: Map<file, Set<file>>, files: Set<file>,
//           builtAtCommit: string|null, confidence: number }
// consumersOf[F] = files that import/source F (the blast-radius seed).
// confidence = resolved / attempted INTERNAL specifiers (external package imports
// are excluded from the denominator). A low value ⇒ graph unreliable ⇒ fail safe.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { basename, dirname, extname, join, normalize } from "node:path";

const JS_EXT = [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".d.ts"];
const JS_SET = new Set([".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte"]);
const SH_SET = new Set([".sh", ".bash"]);
// Languages we resolve reliably enough to TRUST a skip. A changed code file whose
// language is not here forces a survey (we can't measure its blast radius).
const WELL_RESOLVED = new Set([...JS_SET, ...SH_SET]);
// All programming-language extensions (used to tell "code we can't graph" apart
// from inert files like .md/.json where zero fan-out is genuinely low-risk).
const CODE_EXT = new Set([
  ...JS_SET, ...SH_SET, ".py", ".go", ".rb", ".rs", ".java", ".kt", ".scala",
  ".php", ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".swift",
]);
const SRC_EXT = CODE_EXT; // files we open and scan for imports

function extOf(file) { return file.endsWith(".d.ts") ? ".d.ts" : extname(file); }
export function isCode(file) { const e = extOf(file); return CODE_EXT.has(e === ".d.ts" ? ".ts" : e); }
export function isWellResolved(file) { const e = extOf(file); return WELL_RESOLVED.has(e === ".d.ts" ? ".ts" : e); }

function git(repo, args) {
  return execFileSync("git", ["-C", repo, ...args], {
    encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 256 * 1024 * 1024,
  });
}

function extractSpecifiers(content, ext) {
  const specs = [];
  const run = (re) => { let m; while ((m = re.exec(content)) !== null) specs.push(m[1]); };
  if (JS_SET.has(ext)) {
    run(/\bimport\s+(?:[\s\S]*?\s+from\s+)?['"]([^'"]+)['"]/g);
    run(/\bexport\s+[\s\S]*?\s+from\s+['"]([^'"]+)['"]/g);
    run(/\brequire\(\s*['"]([^'"]+)['"]\s*\)/g);
    run(/\bimport\(\s*['"]([^'"]+)['"]\s*\)/g);
  } else if (SH_SET.has(ext)) {
    // Any reference to a .sh/.bash file is treated as a source/dependency edge.
    // This survives command-substitution paths like `source "$(dirname …)/lib/x.sh"`
    // and variable paths like `source "${DIR}/lib/x.sh"` that a `\S+` capture breaks on.
    run(/([^\s'"()]*\.(?:sh|bash))\b/g);
  } else if (ext === ".py") {
    run(/^\s*from\s+([.\w]+)\s+import\b/gm); run(/^\s*import\s+([.\w]+)/gm);
  } else if (ext === ".go") {
    run(/^\s*import\s+"([^"]+)"/gm);
    let g; const grouped = /import\s*\(([\s\S]*?)\)/g;
    while ((g = grouped.exec(content)) !== null) { let s; const inner = /"([^"]+)"/g; while ((s = inner.exec(g[1])) !== null) specs.push(s[1]); }
  } else if (ext === ".rb") { run(/\brequire(?:_relative)?\s+['"]([^'"]+)['"]/g); }
  else if (ext === ".rs") { run(/^\s*use\s+([\w:]+)/gm); }
  else if ([".java", ".kt", ".scala"].includes(ext)) { run(/^\s*import\s+(?:static\s+)?([\w.]+)/gm); }
  else if (ext === ".php") { run(/\b(?:require|include)(?:_once)?\s*\(?\s*['"]([^'"]+)['"]/g); run(/^\s*use\s+([\w\\]+)/gm); }
  else if ([".c", ".h", ".cc", ".cpp", ".hpp"].includes(ext)) { run(/#\s*include\s+"([^"]+)"/g); }
  else if (ext === ".cs") { run(/^\s*using\s+(?:static\s+)?([\w.]+)\s*;/gm); }
  else if (ext === ".swift") { run(/^\s*import\s+(\w+)/gm); }
  return specs.filter(Boolean);
}

// Strip JSONC comments WITHOUT touching // or /* inside string literals — a naive
// regex mangles configs like {"@/*": ["./*"]} where `/*` lives in a string.
function stripJsonc(s) {
  let out = "", i = 0, inStr = false, q = "";
  while (i < s.length) {
    const c = s[i], c2 = s[i + 1];
    if (inStr) { out += c; if (c === "\\") { out += s[i + 1] ?? ""; i += 2; continue; } if (c === q) inStr = false; i++; continue; }
    if (c === '"' || c === "'") { inStr = true; q = c; out += c; i++; continue; }
    if (c === "/" && c2 === "/") { while (i < s.length && s[i] !== "\n") i++; continue; }
    if (c === "/" && c2 === "*") { i += 2; while (i < s.length && !(s[i] === "*" && s[i + 1] === "/")) i++; i += 2; continue; }
    out += c; i++;
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

function readTsAliases(repo) {
  const aliases = []; let baseUrl = ".";
  for (const name of ["tsconfig.json", "jsconfig.json"]) {
    const p = join(repo, name);
    if (!existsSync(p)) continue;
    try {
      const co = (JSON.parse(stripJsonc(readFileSync(p, "utf8"))).compilerOptions) || {};
      if (co.baseUrl) baseUrl = co.baseUrl;
      for (const [k, v] of Object.entries(co.paths || {})) {
        aliases.push({ prefix: k.replace(/\*$/, ""), targets: (Array.isArray(v) ? v : [v]).map((t) => join(baseUrl, t.replace(/\*$/, ""))) });
      }
    } catch { /* malformed config → no aliases */ }
    break;
  }
  return { baseUrl, aliases };
}

function resolveJs(spec, fromFile, fileSet, ts) {
  const candidates = [];
  if (spec.startsWith(".")) candidates.push(normalize(join(dirname(fromFile), spec)));
  else {
    let aliased = false;
    for (const a of ts.aliases) if (a.prefix && spec.startsWith(a.prefix)) { for (const t of a.targets) candidates.push(normalize(join(t, spec.slice(a.prefix.length)))); aliased = true; }
    if (!aliased && ts.baseUrl) candidates.push(normalize(join(ts.baseUrl, spec)));
  }
  for (const base of candidates) {
    if (fileSet.has(base)) return base;
    for (const e of JS_EXT) if (fileSet.has(base + e)) return base + e;
    for (const e of JS_EXT) if (fileSet.has(join(base, "index" + e))) return join(base, "index" + e);
  }
  return null;
}

// Is this a specifier we even ATTEMPT to resolve to a repo file? (external package
// imports are not — they must not count against confidence).
function isInternal(spec, ext) {
  if (JS_SET.has(ext)) return spec.startsWith(".") || spec.startsWith("@/") || spec.startsWith("~");
  if (SH_SET.has(ext)) return true; // sourced files are always local
  if ([".c", ".h", ".cc", ".cpp", ".hpp"].includes(ext)) return true; // #include "..." is local
  if (ext === ".rb") return spec.startsWith(".") || spec.includes("/");
  return false; // dotted-module languages: treated as external (kept out of denominator)
}

export function buildConsumerGraph(repo) {
  let tracked = [], builtAtCommit = null;
  try {
    tracked = git(repo, ["ls-files"]).split("\n").map((s) => s.trim()).filter(Boolean);
    builtAtCommit = git(repo, ["rev-parse", "HEAD"]).trim();
  } catch { /* not a git repo */ }

  const fileSet = new Set(tracked);
  // basename → tracked files, for shell `source`/`.` whose paths carry shell vars.
  const byBasename = new Map();
  for (const f of tracked) { const b = basename(f); if (!byBasename.has(b)) byBasename.set(b, []); byBasename.get(b).push(f); }
  const ts = readTsAliases(repo);
  const consumersOf = new Map();
  let attempted = 0, resolvedCount = 0;

  const addEdge = (target, consumer) => {
    if (!target || target === consumer) return;
    if (!consumersOf.has(target)) consumersOf.set(target, new Set());
    consumersOf.get(target).add(consumer);
  };

  for (const file of tracked) {
    let ext = extOf(file);
    let content;
    if (!SRC_EXT.has(ext) && ext !== ".d.ts") {
      if (ext !== "") continue; // a non-source extension → skip
      // Extensionless file (e.g. bin/dar): treat as shell if it has a sh shebang.
      try { content = readFileSync(join(repo, file), "utf8"); } catch { continue; }
      if (/^#!.*\b(?:ba|z|k)?sh\b/.test(content.slice(0, 120))) ext = ".sh"; else continue;
    }
    if (content === undefined) { try { content = readFileSync(join(repo, file), "utf8"); } catch { continue; } }
    if (content.length > 2 * 1024 * 1024) continue;
    for (const spec of extractSpecifiers(content, ext)) {
      const internal = isInternal(spec, ext);
      if (internal) attempted++;
      let target = null;
      if (JS_SET.has(ext)) target = resolveJs(spec, file, fileSet, ts);
      else if (SH_SET.has(ext)) {
        const b = basename(spec.replace(/['"]/g, "")); // strip quotes; vars remain in dir part
        const hits = byBasename.get(b);
        if (hits && hits.length === 1) target = hits[0]; // unambiguous basename match
      } else if ([".c", ".h", ".cc", ".cpp", ".hpp"].includes(ext) || (ext === ".rb" && spec.includes("/"))) {
        const c = normalize(join(dirname(file), spec));
        if (fileSet.has(c)) target = c; else for (const e of [".h", ".hpp", ".rb"]) if (fileSet.has(c + e)) { target = c + e; break; }
      }
      if (internal && target) resolvedCount++;
      addEdge(target, file);
    }
  }

  const confidence = attempted === 0 ? 1 : resolvedCount / attempted;
  return { consumersOf, files: fileSet, builtAtCommit, confidence };
}
