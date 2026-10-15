import { execFileSync } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { basename, extname, join, resolve } from "node:path";

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

// what git would commit: scratch notes and build output are not docs
function listProjectFiles() {
  try {
    return execFileSync(
      "git",
      ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
      {
        cwd: PROJECT_ROOT,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      },
    )
      .split("\0")
      .filter(Boolean);
  } catch (error) {
    console.error(
      `check-paths reads the file list from git, and ${PROJECT_ROOT} is not a git checkout: ${error.message}`,
    );
    process.exit(1);
  }
}

const projectFiles = listProjectFiles();

function filesMatching(matches, skipDirs = SKIP_DIRS) {
  return projectFiles
    .filter((path) => !path.split("/").some((part) => skipDirs.has(part)))
    .filter((path) => matches(basename(path)))
    .map((path) => join(PROJECT_ROOT, path))
    .filter((path) => existsSync(path));
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

for (const file of filesMatching(
  (name) => name.endsWith(".md"),
  MARKDOWN_SKIP_DIRS,
)) {
  for (const path of missingPaths(await readFile(file, "utf8"))) {
    failures.push(`${file}: no such path: ${path}`);
  }
}

const shippedNumbers = await shippedAdrNumbers();
const adrScanFiles = filesMatching((name) =>
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
