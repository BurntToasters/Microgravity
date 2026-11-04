import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { generateProject } from "./generate-project.mjs";
import { ensureDirectory, output, root, run, versionInfo } from "./lib/core.mjs";
import { validateWorkspace } from "./validate.mjs";

const project = "Microgravity.xcodeproj";
const derivedData = "DerivedData/Build";
const pathArguments = new Set(["-derivedDataPath", "-clonedSourcePackagesDirPath", "-packageCachePath"]);

export function absoluteToolPaths(args) {
  const result = [...args];
  for (let index = 0; index < result.length - 1; index += 1) {
    if (pathArguments.has(result[index])) result[index + 1] = path.resolve(root, result[index + 1]);
  }
  return result;
}

function xcodeEnvironment({ skipEmbedSigning = true } = {}) {
  const publicKey = process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY ?? "";
  return {
    MICROGRAVITY_SPARKLE_PUBLIC_KEY: publicKey,
    MICROGRAVITY_SKIP_EMBED_SIGNING: skipEmbedSigning ? "1" : "0",
  };
}

export function debugBuildArguments({ architecture = os.arch() === "x64" ? "x86_64" : "arm64", derived = derivedData } = {}) {
  return ["-project", project, "-scheme", "Debug", "-configuration", "Debug", "-derivedDataPath", derived, "-clonedSourcePackagesDirPath", "DerivedData/SourcePackages", "-packageCachePath", "DerivedData/PackageCache", "-destination", `platform=macOS,arch=${architecture}`, "build", "CODE_SIGNING_ALLOWED=NO"];
}

export function releaseSmokeArguments({ derived = "DerivedData/ReleaseSmoke" } = {}) {
  return ["-project", project, "-scheme", "Release", "-configuration", "Release", "-derivedDataPath", derived, "-clonedSourcePackagesDirPath", "DerivedData/SourcePackages", "-packageCachePath", "DerivedData/PackageCache", "-destination", "generic/platform=macOS", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", "build"];
}

function updateBuildSettingsArguments() {
  return [`SPARKLE_ENABLE_AUTOMATIC_CHECKS=${process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY ? "YES" : "NO"}`];
}

export function resolvePackages(buildArgs) {
  const value = (flag) => buildArgs[buildArgs.indexOf(flag) + 1];
  const args = absoluteToolPaths(["-resolvePackageDependencies", "-project", project, "-scheme", value("-scheme"), "-derivedDataPath", value("-derivedDataPath"), "-clonedSourcePackagesDirPath", value("-clonedSourcePackagesDirPath"), "-packageCachePath", value("-packageCachePath")]);
  run("xcodebuild", args, { env: xcodeEnvironment() });
}

export function buildDebug() {
  generateProject();
  validateWorkspace();
  const args = absoluteToolPaths(debugBuildArguments());
  args.push(...updateBuildSettingsArguments());
  resolvePackages(args);
  run("xcodebuild", args, { env: xcodeEnvironment() });
  const app = path.join(root, derivedData, "Build/Products/Debug/Microgravity.app");
  validateWorkspace({ bundle: app });
  console.log("build:debug: ok (unsigned development app)");
  return app;
}

export function buildReleaseSmoke() {
  generateProject();
  validateWorkspace();
  const args = absoluteToolPaths(releaseSmokeArguments());
  args.push(...updateBuildSettingsArguments());
  resolvePackages(args);
  run("xcodebuild", args, { env: xcodeEnvironment() });
  console.log("build:release-smoke: ok (unsigned universal Release compile)");
}

export function releaseSigningTargets(app) {
  const sparkle = path.join(app, "Contents/Frameworks/Sparkle.framework");
  return [
    path.join(sparkle, "Versions/A/Autoupdate"),
    path.join(sparkle, "Versions/A/Updater.app"),
    sparkle,
    path.join(app, "Contents/Helpers/MicrogravityHelper"),
    app,
  ];
}

export function releaseCodesignArguments(target, { identity, entitlements, isApp = false, identifier }) {
  return ["--force", "--options", "runtime", "--timestamp", "--sign", identity, ...(identifier ? ["--identifier", identifier] : []), ...(isApp ? ["--entitlements", entitlements] : []), target];
}

function isMachO(file) {
  const descriptor = fs.openSync(file, "r");
  try {
    const head = Buffer.alloc(4);
    const count = fs.readSync(descriptor, head, 0, 4, 0);
    if (count < 4) return false;
    return [0xcffaedfe, 0xcefaedfe, 0xfeedfacf, 0xfeedface, 0xcafebabe, 0xcafebabf].includes(head.readUInt32BE(0));
  } finally {
    fs.closeSync(descriptor);
  }
}

function collectCode(app) {
  const binaries = [];
  const bundles = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (/\.(?:app|framework|xpc)$/.test(entry.name)) bundles.push(absolute);
        visit(absolute);
      } else if (entry.isFile() && isMachO(absolute)) binaries.push(absolute);
    }
  };
  visit(app);
  return {
    binaries: binaries.filter((file) => file !== path.join(app, "Contents/MacOS/Microgravity")),
    bundles: bundles.sort((left, right) => right.split(path.sep).length - left.split(path.sep).length),
  };
}

function signRelease(app, identity) {
  const entitlements = path.join(root, "Microgravity.entitlements");
  const { binaries, bundles } = collectCode(app);
  const helper = path.join(app, "Contents/Helpers/MicrogravityHelper");
  for (const binary of binaries) run("codesign", releaseCodesignArguments(binary, { identity, identifier: binary === helper ? "run.rosie.microgravity.helper" : undefined }));
  for (const bundle of bundles) run("codesign", releaseCodesignArguments(bundle, { identity }));
  run("codesign", releaseCodesignArguments(app, { identity, entitlements, isApp: true }));
  run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", app]);

  const result = run("codesign", ["-dv", "--verbose=4", app], { capture: true, allowFailure: true });
  const details = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const team = details.match(/^TeamIdentifier=(\S+)$/m)?.[1];
  if (team !== process.env.MICROGRAVITY_TEAM_ID) throw new Error(`release app team ${team ?? "unknown"} does not match MICROGRAVITY_TEAM_ID`);
  const helperDetails = run("codesign", ["-dv", "--verbose=4", helper], { capture: true, allowFailure: true });
  const helperText = `${helperDetails.stdout ?? ""}\n${helperDetails.stderr ?? ""}`;
  if (helperText.match(/^TeamIdentifier=(\S+)$/m)?.[1] !== team || helperText.match(/^Identifier=(\S+)$/m)?.[1] !== "run.rosie.microgravity.helper") throw new Error("helper signing identity or team mismatch");
}

function packageZip(app, zip) {
  fs.rmSync(zip, { force: true });
  run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, zip]);
}

export function buildRelease() {
  generateProject();
  validateWorkspace({ release: true });
  const { version } = versionInfo();
  const dist = path.join(root, "dist");
  const releaseDerived = path.join(dist, "DerivedData");
  const app = path.join(dist, "Microgravity.app");
  const zip = path.join(dist, `Microgravity-${version}.zip`);
  fs.rmSync(dist, { recursive: true, force: true });
  ensureDirectory(dist);
  const args = absoluteToolPaths(["-project", project, "-scheme", "Release", "-configuration", "Release", "-derivedDataPath", releaseDerived, "-clonedSourcePackagesDirPath", "DerivedData/SourcePackages", "-packageCachePath", "DerivedData/PackageCache", "-destination", "generic/platform=macOS", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", "clean", "build", ...updateBuildSettingsArguments()]);
  resolvePackages(args);
  run("xcodebuild", args, { env: xcodeEnvironment() });
  const builtApp = path.join(releaseDerived, "Build/Products/Release/Microgravity.app");
  run("ditto", [builtApp, app]);
  const architectures = output("lipo", ["-archs", path.join(app, "Contents/MacOS/Microgravity")]).split(/\s+/).sort();
  if (architectures.join(" ") !== "arm64 x86_64") throw new Error(`release executable is not universal: ${architectures.join(" ")}`);

  const identity = process.env.MICROGRAVITY_SIGNING_IDENTITY;
  for (const binary of collectCode(app).binaries) {
    const slices = output("lipo", ["-archs", binary]).split(/\s+/).sort();
    if (slices.join(" ") !== "arm64 x86_64") throw new Error(`release binary is not universal: ${binary}: ${slices.join(" ")}`);
  }
  signRelease(app, identity);
  packageZip(app, zip);
  run("xcrun", ["notarytool", "submit", zip, "--keychain-profile", process.env.MICROGRAVITY_NOTARY_PROFILE, "--wait", "--timeout", "45m"]);
  run("xcrun", ["stapler", "staple", app]);
  run("xcrun", ["stapler", "validate", app]);
  run("spctl", ["--assess", "--type", "execute", "--verbose=4", app]);
  packageZip(app, zip);
  validateWorkspace({ release: true, bundle: app });
  console.log(`build:release: ok (${path.basename(zip)})`);
  return { app, zip, architectures };
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    const action = process.argv[2] ?? "debug";
    if (action === "debug") buildDebug();
    else if (action === "release-smoke") buildReleaseSmoke();
    else if (action === "release") buildRelease();
    else throw new Error(`Unknown build action '${action}'; use debug, release-smoke, or release.`);
  } catch (error) {
    console.error(`build: FAILED:\n${error.message}`);
    process.exit(1);
  }
}
