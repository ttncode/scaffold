import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

const DOCS_DIR = resolve(import.meta.dirname, "..");
const PROJECT_ROOT = resolve(DOCS_DIR, "..");
// backticked strings that look like repository paths
const PATH_PATTERN = /`((?:[\w.-]+\/)+[\w.-]+)`/g;

// node_modules ships its own markdown, full of paths relative to whatever
// package it belongs to, not this project; nothing here authored it.
const SKIP_DIRS = new Set(["node_modules", ".vitepress"]);

async function markdownFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = await Promise.all(
    entries.map((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        return SKIP_DIRS.has(entry.name) ? [] : markdownFiles(path);
      }
      return entry.name.endsWith(".md") ? [path] : [];
    }),
  );
  return files.flat();
}

function missingPaths(content) {
  return [...content.matchAll(PATH_PATTERN)]
    .map((match) => match[1])
    .filter((candidate) => !candidate.includes("://"))
    .filter((candidate) => !existsSync(resolve(PROJECT_ROOT, candidate)));
}

const failures = [];
for (const file of await markdownFiles(DOCS_DIR)) {
  for (const path of missingPaths(await readFile(file, "utf8"))) {
    failures.push(`${file}: no such path: ${path}`);
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
