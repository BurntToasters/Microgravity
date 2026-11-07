import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { fail, root, versionInfo, writeIfChanged } from "./lib/core.mjs";
import { expectedChangelog } from "./lib/changelog.mjs";

// xcconfig treats // as a comment, so the slashes are escaped as `:/$()/`; `$()` expands to nothing.
export function sparkleFeedValue(version) {
  const appcast = version.includes("-beta.") ? "appcast-beta.xml" : "appcast.xml";
  return `https:/$()/github.com/BurntToasters/Microgravity/releases/latest/download/${appcast}`;
}

export function expectedVersionConfig(base = root) {
  const { version, buildNumber } = versionInfo(base);
  return [
    `MARKETING_VERSION = ${version}`,
    `CURRENT_PROJECT_VERSION = ${buildNumber}`,
    "SPARKLE_PUBLIC_KEY = $(MICROGRAVITY_SPARKLE_PUBLIC_KEY)",
    "SPARKLE_ENABLE_AUTOMATIC_CHECKS = NO",
    `SPARKLE_FEED_URL = ${sparkleFeedValue(version)}`,
    "",
  ].join("\n");
}

export function expectedPackageLock(current, version) {
  const lock = JSON.parse(current);
  lock.version = version;
  if (lock.packages?.[""]) lock.packages[""].version = version;
  return `${JSON.stringify(lock, null, 2)}\n`;
}

function versionTargets(base) {
  const { version } = versionInfo(base);
  const read = (relative) => fs.readFileSync(path.join(base, relative), "utf8");
  return [
    { file: "config/version.xcconfig", current: read("config/version.xcconfig"), expected: expectedVersionConfig(base) },
    { file: "package-lock.json", current: read("package-lock.json"), expected: expectedPackageLock(read("package-lock.json"), version) },
    { file: "CHANGELOG.md", current: read("CHANGELOG.md"), expected: expectedChangelog(read("CHANGELOG.md"), version) },
  ];
}

export function syncVersion({ base = root, check = false } = {}) {
  let targets;
  try {
    targets = versionTargets(base);
  } catch (error) {
    if (error.code === "ENOENT") fail(`Version sync input is missing: ${error.path}`);
    throw error;
  }
  if (check) {
    const stale = targets.filter(({ current, expected }) => current !== expected).map(({ file }) => file);
    if (stale.length) fail(`${stale.join(", ")} ${stale.length === 1 ? "is" : "are"} stale; run npm run sync-version and commit the result.`);
    return false;
  }
  return targets.map(({ file, expected }) => writeIfChanged(path.join(base, file), expected)).some(Boolean);
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    const check = process.argv.includes("--check");
    const changed = syncVersion({ check });
    console.log(`sync-version: ${check ? "committed versions are current" : changed ? "updated" : "already current"}`);
  } catch (error) {
    console.error(`sync-version: FAILED: ${error.message}`);
    process.exit(1);
  }
}
