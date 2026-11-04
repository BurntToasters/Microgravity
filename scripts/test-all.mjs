import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { absoluteToolPaths, resolvePackages } from "./build.mjs";
import { clearProof, recordProof } from "./release-session.mjs";
import { root, run } from "./lib/core.mjs";

function nodeTests() {
  const directory = path.join(root, "scripts/tests");
  const tests = fs.readdirSync(directory).filter((file) => file.endsWith(".test.mjs")).sort().map((file) => path.join(directory, file));
  run(process.execPath, ["--test", ...tests]);
}

function xcodeTests() {
  const architecture = os.arch() === "x64" ? "x86_64" : "arm64";
  const resultBundle = path.join(root, "DerivedData/TestResults/Microgravity.xcresult");
  fs.rmSync(resultBundle, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(resultBundle), { recursive: true });
  const args = absoluteToolPaths([
    "-project", "Microgravity.xcodeproj",
    "-scheme", "Test",
    "-configuration", "Debug",
    "-derivedDataPath", "DerivedData/Tests",
    "-clonedSourcePackagesDirPath", "DerivedData/SourcePackages",
    "-packageCachePath", "DerivedData/PackageCache",
    "-destination", `platform=macOS,arch=${architecture}`,
    "-parallel-testing-enabled", "NO",
    "-resultBundlePath", resultBundle,
    "test",
    "CODE_SIGNING_ALLOWED=NO",
    `SPARKLE_ENABLE_AUTOMATIC_CHECKS=${process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY ? "YES" : "NO"}`,
  ]);
  resolvePackages(args);
  run("xcodebuild", args, { env: { MICROGRAVITY_SPARKLE_PUBLIC_KEY: process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY ?? "", MICROGRAVITY_SKIP_EMBED_SIGNING: "1" } });
}

export function runAllTests() {
  clearProof();
  run(process.execPath, ["scripts/sync-version.mjs", "--check"]);
  run(process.execPath, ["scripts/generate-project.mjs", "--check"]);
  run(process.execPath, ["scripts/validate.mjs"]);
  nodeTests();
  xcodeTests();
  if (run("git", ["status", "--porcelain"], { capture: true }).stdout) {
    console.log("test:all: ok (dirty worktree; no reusable release proof recorded)");
  } else {
    recordProof();
    console.log("test:all: ok (24-hour release proof recorded)");
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  if (process.argv.slice(2).some((argument) => argument === "--help" || argument === "-h")) {
    console.log("Usage: node scripts/test-all.mjs");
    console.log("Runs version, project, workspace, Node, Core XCTest, and UI XCTest gates.");
  } else {
    try {
      runAllTests();
    } catch (error) {
      console.error(`test:all: FAILED:\n${error.message}`);
      process.exit(1);
    }
  }
}
