import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve } from "node:path";

const DOCS_DIR = resolve(import.meta.dirname, "..");
const PROJECT_ROOT = resolve(DOCS_DIR, "..");
// backticked strings that look like repository paths
const PATH_PATTERN = /`((?:[\w.-]+\/)+[\w.-]+)`/g;
// a comment citing an adr by path, not just by prose in a backtick — the
// shape task 6 and task 9 both got wrong, in files that ship (compose.yaml,
// install.sh, an adapter's own mise.toml), while what they meant was the
// scaffold toolbox's own history, which never ships past 0000 and the
// template (see common/docs/decisions/).
const ADR_REFERENCE_PATTERN = /\bdocs\/decisions\/(\d{4})[\w.-]*/g;
const ADR_SCAN_EXTENSIONS = new Set([".sh", ".toml", ".mjs", ".yaml", ".yml"]);

// node_modules and .git ship files nothing here authored — vendor markdown
// full of paths relative to whatever package it belongs to, or plumbing
// with no bearing on this project's own docs or adr citations.
const SKIP_DIRS = new Set(["node_modules", ".git", ".vitepress"]);

async function filesMatching(dir, matches) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = await Promise.all(
    entries.map((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        return SKIP_DIRS.has(entry.name) ? [] : filesMatching(path, matches);
      }
      return matches(entry.name) ? [path] : [];
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

async function shippedAdrNumbers() {
  const decisionsDir = resolve(PROJECT_ROOT, "docs/decisions");
  if (!existsSync(decisionsDir)) return new Set();
  const names = await readdir(decisionsDir);
  return new Set(names.map((name) => name.slice(0, 4)));
}

function missingAdrReferences(content, shippedNumbers) {
  return [...content.matchAll(ADR_REFERENCE_PATTERN)]
    .filter(([, number]) => !shippedNumbers.has(number))
    .map(([reference]) => reference);
}

const failures = [];

for (const file of await filesMatching(DOCS_DIR, (name) =>
  name.endsWith(".md"),
)) {
  for (const path of missingPaths(await readFile(file, "utf8"))) {
    failures.push(`${file}: no such path: ${path}`);
  }
}

const shippedNumbers = await shippedAdrNumbers();
const adrScanFiles = await filesMatching(PROJECT_ROOT, (name) =>
  ADR_SCAN_EXTENSIONS.has(extname(name)),
);
for (const file of adrScanFiles) {
  for (const reference of missingAdrReferences(
    await readFile(file, "utf8"),
    shippedNumbers,
  )) {
    failures.push(
      `${file}: cites an adr that does not ship here: ${reference}`,
    );
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
