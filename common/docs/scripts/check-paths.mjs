import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve } from "node:path";

const PROJECT_ROOT = resolve(import.meta.dirname, "..", "..");
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
// apps/ ships generator-owned markdown (AGENTS.md, README.md) whose backticked
// paths are written relative to the app's own directory, not the project
// root, so the root-relative path scan reports them as dead when they are not
// (e.g. create-next-app's AGENTS.md and README.md). This applies to the
// markdown path scan only — the ADR-citation scan must still walk apps/, or
// a dead ADR reference in an adapter's own mise.toml goes unseen again
// (the hole task 11 closed).
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

// the whole project, not just docs/ — a backticked dead path in
// deploy-adapters/README.md is the same defect as one in docs/index.md.
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
