// Node unit tests for the native graph classifiers + builder (no external deps).
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { isCode, isWellResolved, isInert, buildConsumerGraph } from "../lib/graph.mjs";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

test("isCode / isWellResolved", () => {
  assert.equal(isCode("a.ts"), true);
  assert.equal(isCode("a.py"), true);
  assert.equal(isCode("a.md"), false);
  assert.equal(isWellResolved("a.ts"), true);
  assert.equal(isWellResolved("a.sh"), true);
  assert.equal(isWellResolved("a.py"), false);      // extractable but not trusted for a skip
  assert.equal(isWellResolved("a.d.ts"), true);
});

test("isInert is narrow — only true docs/assets", () => {
  for (const f of ["README.md", "docs/guide.mdx", "notes.txt", "LICENSE", "img/logo.png"])
    assert.equal(isInert(f), true, `${f} should be inert`);
  // Control surfaces that look inert must NOT be inert.
  for (const f of [".gitignore", ".gitattributes", "CODEOWNERS", "CLAUDE.md", "AGENTS.md",
    ".claude-plugin/marketplace.json", "schemas/review.schema.json", "Dockerfile",
    ".github/workflows/ci.yml", "package.json", "config.yaml"])
    assert.equal(isInert(f), false, `${f} must not be inert`);
});

test("buildConsumerGraph returns per-file counts + confidence", () => {
  const g = buildConsumerGraph(repoRoot);
  assert.ok(g.files instanceof Set && g.files.size > 0);
  assert.ok(g.consumersOf instanceof Map);
  assert.ok(g.perFile instanceof Map, "perFile map present");
  assert.ok(typeof g.confidence === "number" && g.confidence >= 0 && g.confidence <= 1);
  // The shared shell lib is sourced by the gate scripts → it must have consumers.
  const consumers = g.consumersOf.get("lib/common.sh");
  assert.ok(consumers && consumers.size >= 1, "lib/common.sh has shell consumers");
});
