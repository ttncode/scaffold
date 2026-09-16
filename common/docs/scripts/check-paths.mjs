import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve } from "node:path";

const PROJECT_ROOT = resolve(import.meta.dirname, "..", "..");
// backticked strings that look like repository paths
const PATH_PATTERN = /`((?:[\w.-]+\/)+[\w.-]+)`/g;
// an adr cited by path in a shipped file must exist in this project's docs/decisions/
const ADR_REFERENCE_PATTERN = /\bdocs\/decisions\/(\d{4})[\w.-]*/g;
const ADR_SCAN_EXTENSIONS = new Set([".sh", ".toml", ".mjs", ".yaml", ".yml"]);

const SKIP_DIRS = new Set(["node_modules", ".git", ".vitepress"]);
// generator-owned markdown under apps/ uses app-relative paths; the adr scan
// still walks apps/
const MARKDOWN_SKIP_DIRS = new Set([...SKIP_DIRS, "apps"]);

async function filesMatching(dir, matches, skipDirs = SKIP_DIRS) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = await Promise.all(
    entries.map((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        return skipDirs.has(entry.name)
          ? []
          : filesMatching(path, matches, skipDirs);
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

for (const file of await filesMatching(
  PROJECT_ROOT,
  (name) => name.endsWith(".md"),
  MARKDOWN_SKIP_DIRS,
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
