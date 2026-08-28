import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const DECISIONS_DIR = resolve(import.meta.dirname, "..", "decisions");
const REQUIRED_SECTIONS = [
  "## Context",
  "## Decision",
  "## Consequences",
  "## Alternatives considered",
];
const VALID_STATUSES = ["Proposed", "Accepted", "Superseded"];

const failures = [];
const seenNumbers = new Map();

for (const name of await readdir(DECISIONS_DIR)) {
  if (!name.endsWith(".md") || name.startsWith("_")) continue;

  const number = name.slice(0, 4);
  if (seenNumbers.has(number)) {
    failures.push(
      `${name}: duplicate number, already used by ${seenNumbers.get(number)}`,
    );
  }
  seenNumbers.set(number, name);

  const content = await readFile(join(DECISIONS_DIR, name), "utf8");

  for (const section of REQUIRED_SECTIONS) {
    if (!content.includes(section)) {
      failures.push(`${name}: missing section ${section}`);
    }
  }

  const status = content.match(/^Status:\s*(\w+)/m)?.[1];
  if (!VALID_STATUSES.includes(status)) {
    failures.push(
      `${name}: status must be one of ${VALID_STATUSES.join(", ")}`,
    );
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
