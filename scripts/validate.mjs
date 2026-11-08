import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { discoverSources, sourceRoots } from "./generate-project.mjs";
import { bundleIdentifier, readPackage, root, run, versionInfo } from "./lib/core.mjs";
import { syncVersion } from "./sync-version.mjs";

const pbxTokens = /\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\/|"((?:\\.|[^"\\])*)"|([A-Za-z0-9_$./:+\-]+)|([\s\S])/g;
const pbxObjectId = /^[0-9A-Z]{24}$/;
// Name of resources/microgravity.icon without its extension; actool names the compiled icon after it.
export const appIconName = "microgravity";

export function parsePbxproj(text) {
  const tokens = [...text.matchAll(pbxTokens)].flatMap((match) => {
    if (match[1] !== undefined) return [{ value: match[1] }];
    if (match[2] !== undefined) return [{ value: match[2] }];
    if (match[3] !== undefined) return [{ value: match[3], punctuation: true }];
    return [];
  });
  const duplicateKeys = [];
  let index = 0;
  const isPunctuation = (value) => tokens[index]?.punctuation === true && tokens[index].value === value;
  const expect = (value) => {
    if (!isPunctuation(value)) throw new Error(`pbxproj: expected "${value}" at token ${index} (${tokens[index]?.value ?? "end of file"})`);
    index++;
  };
  const parseValue = () => {
    if (isPunctuation("{")) {
      index++;
      const dictionary = {};
      while (!isPunctuation("}")) {
        if (index >= tokens.length) throw new Error("pbxproj: unterminated dictionary");
        const key = tokens[index++].value;
        expect("=");
        if (Object.hasOwn(dictionary, key)) duplicateKeys.push(key);
        dictionary[key] = parseValue();
        expect(";");
      }
      index++;
      return dictionary;
    }
    if (isPunctuation("(")) {
      index++;
      const list = [];
      while (!isPunctuation(")")) {
        if (index >= tokens.length) throw new Error("pbxproj: unterminated list");
        list.push(parseValue());
        if (isPunctuation(",")) index++;
      }
      index++;
      return list;
    }
    if (index >= tokens.length) throw new Error("pbxproj: unexpected end of file");
    return tokens[index++].value;
  };
  const document = parseValue();
  if (index !== tokens.length) throw new Error(`pbxproj: trailing content at token ${index}`);
  return { document, duplicateKeys };
}

function visitObjectIds(value, visit) {
  if (typeof value === "string") {
    if (pbxObjectId.test(value)) visit(value);
  } else if (Array.isArray(value)) {
    for (const item of value) visitObjectIds(item, visit);
  } else if (value && typeof value === "object") {
    for (const item of Object.values(value)) visitObjectIds(item, visit);
  }
}

export function checkProject(text, { base = root } = {}) {
  const failures = [];
  if (/^(<<<<<<<|=======|>>>>>>>)/m.test(text)) failures.push("pbxproj: conflict marker remains");
  let parsed;
  try { parsed = parsePbxproj(text); } catch (error) { return [...failures, error.message]; }
  for (const key of new Set(parsed.duplicateKeys)) failures.push(`pbxproj: duplicate key ${key}`);

  const objects = parsed.document.objects ?? {};
  const project = objects[parsed.document.rootObject];
  if (!project || project.isa !== "PBXProject") failures.push("pbxproj: rootObject is not a PBXProject");
  const undefinedIds = new Set();
  for (const [id, object] of Object.entries(objects)) {
    visitObjectIds(object, (reference) => {
      if (!Object.hasOwn(objects, reference)) undefinedIds.add(`${reference} (in ${id})`);
    });
  }
  visitObjectIds(parsed.document.rootObject, (reference) => {
    if (!Object.hasOwn(objects, reference)) undefinedIds.add(`${reference} (rootObject)`);
  });
  for (const reference of undefinedIds) failures.push(`pbxproj: undefined object ID ${reference}`);

  for (const [id, object] of Object.entries(objects)) {
    if (object.isa !== "PBXFileReference") continue;
    const file = object.path ?? object.name;
    if (object.sourceTree === "SOURCE_ROOT" && file && !fs.existsSync(path.join(base, file))) failures.push(`pbxproj: file reference ${id} points at missing ${file}`);
  }

  const syncGroups = new Map(Object.entries(objects).filter(([, object]) => object.isa === "PBXFileSystemSynchronizedRootGroup").map(([id, object]) => [id, object.path]));
  const targets = Object.fromEntries(Object.values(objects).filter((object) => object.isa === "PBXNativeTarget").map((object) => [object.name, object]));
  const expectedMembership = {
    Microgravity: sourceRoots.app,
    MicrogravityHelper: sourceRoots.helper,
    MicrogravityCoreTests: sourceRoots.coreTests,
    MicrogravityUITests: sourceRoots.uiTests,
  };
  for (const [targetName, directories] of Object.entries(expectedMembership)) {
    const target = targets[targetName];
    if (!target) {
      failures.push(`pbxproj: missing target ${targetName}`);
      continue;
    }
    const actual = (target.fileSystemSynchronizedGroups ?? []).map((id) => syncGroups.get(id)).filter(Boolean);
    for (const directory of directories) if (!actual.includes(directory)) failures.push(`pbxproj: ${targetName} does not discover ${directory}`);
    for (const source of discoverSources(base)[targetName === "Microgravity" ? "app" : targetName === "MicrogravityHelper" ? "helper" : targetName === "MicrogravityCoreTests" ? "coreTests" : "uiTests"]) {
      const directory = directories.find((entry) => source.startsWith(`${entry}/`));
      if (directory && !actual.includes(directory)) failures.push(`pbxproj: ${source} is outside its target's synchronized groups`);
    }
  }
  const appSettings = (objects[targets.Microgravity?.buildConfigurationList]?.buildConfigurations ?? []).map((id) => objects[id]?.buildSettings ?? {});
  if (appSettings.length === 0 || appSettings.some((settings) => settings.ASSETCATALOG_COMPILER_APPICON_NAME !== appIconName)) {
    failures.push(`pbxproj: Microgravity app configurations must set ASSETCATALOG_COMPILER_APPICON_NAME = ${appIconName}`);
  }
  const appPhases = (targets.Microgravity?.buildPhases ?? []).map((id) => objects[id]).filter(Boolean);
  const daemonPhase = appPhases.find((phase) => phase.isa === "PBXCopyFilesBuildPhase" && phase.dstSubfolderSpec === "1" && phase.dstPath === "Contents/Library/LaunchDaemons");
  const copiedDaemon = (daemonPhase?.files ?? []).some((id) => {
    const ref = objects[objects[id]?.fileRef];
    return ref?.path === "resources/helper/run.rosie.microgravity.helper.plist" && ref.sourceTree === "SOURCE_ROOT";
  });
  if (!copiedDaemon) failures.push("pbxproj: helper launch daemon plist must be copied into the app's LaunchDaemons directory");
  if (targets.Microgravity?.productType !== "com.apple.product-type.application") failures.push("pbxproj: Microgravity must be an application target");
  if (targets.MicrogravityHelper?.productType !== "com.apple.product-type.tool") failures.push("pbxproj: MicrogravityHelper must be a command-line tool target");
  if (targets.MicrogravityCoreTests?.productType !== "com.apple.product-type.bundle.unit-test") failures.push("pbxproj: CoreTests must be an XCTest unit-test bundle");
  if (targets.MicrogravityUITests?.productType !== "com.apple.product-type.bundle.ui-testing") failures.push("pbxproj: UITests must be an XCTest UI-test bundle");
  if (!text.includes("XCLocalSwiftPackageReference \"vendor/Sparkle\"") || !text.includes("productName = Sparkle")) failures.push("pbxproj: local Sparkle package reference is missing");
  for (const scheme of ["Debug", "Release", "Test"]) {
    const file = path.join(base, "Microgravity.xcodeproj/xcshareddata/xcschemes", `${scheme}.xcscheme`);
    if (!fs.existsSync(file)) failures.push(`xcode scheme is missing: ${scheme}`);
    else if (scheme === "Test") {
      const contents = fs.readFileSync(file, "utf8");
      for (const targetName of ["MicrogravityCoreTests", "MicrogravityUITests"]) {
        if (!contents.includes(`BlueprintName="${targetName}"`)) failures.push(`Test scheme does not include ${targetName}`);
      }
      if (!contents.includes("<MacroExpansion>")) failures.push("Test scheme has no app macro expansion");
    }
  }
  return failures;
}

function add(failures, condition, message) {
  if (!condition) failures.push(message);
}

export function releaseSettingsFailures(environment = process.env) {
  const failures = [];
  for (const name of ["MICROGRAVITY_SPARKLE_PUBLIC_KEY", "MICROGRAVITY_SIGNING_IDENTITY", "MICROGRAVITY_TEAM_ID", "MICROGRAVITY_NOTARY_PROFILE", "MICROGRAVITY_GPG_KEY"]) {
    if (!environment[name]) failures.push(`${name} is required for release builds`);
  }
  const sources = ["MICROGRAVITY_SPARKLE_ACCOUNT", "MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE", "MICROGRAVITY_SPARKLE_PRIVATE_KEY"].filter((name) => environment[name]);
  if (sources.length !== 1) failures.push("configure exactly one Sparkle signing credential source");
  if (environment.MICROGRAVITY_SPARKLE_PUBLIC_KEY) {
    const key = environment.MICROGRAVITY_SPARKLE_PUBLIC_KEY;
    const decoded = /^[A-Za-z0-9+/]+={0,2}$/.test(key) ? Buffer.from(key, "base64") : Buffer.alloc(0);
    if (decoded.length !== 32 || decoded.toString("base64") !== key) failures.push("MICROGRAVITY_SPARKLE_PUBLIC_KEY is not a valid Sparkle public key");
  }
  if (environment.MICROGRAVITY_TEAM_ID && !/^[A-Z0-9]{10}$/.test(environment.MICROGRAVITY_TEAM_ID)) failures.push("MICROGRAVITY_TEAM_ID must be a 10-character Apple Team ID");
  if (environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE && !fs.existsSync(path.resolve(root, environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE))) failures.push("configured Sparkle private-key file does not exist");
  return failures;
}

function bundleValue(bundle, key) {
  return String(run("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, path.join(bundle, "Contents/Info.plist")], { capture: true }).stdout).trim();
}

export function helperPlistFailures(plist) {
  const failures = [];
  if (plist.Label !== "run.rosie.microgravity.helper") failures.push("helper plist Label mismatch");
  if (plist.BundleProgram !== "Contents/Helpers/MicrogravityHelper") failures.push("helper plist BundleProgram mismatch");
  if (plist.MachServices?.["run.rosie.microgravity.helper"] !== true) failures.push("helper plist MachServices mismatch");
  return failures;
}

function checkHelperPlist(file, failures) {
  try {
    const result = run("plutil", ["-convert", "json", "-o", "-", file], { capture: true });
    failures.push(...helperPlistFailures(JSON.parse(result.stdout)).map((message) => `${file}: ${message}`));
  } catch (error) { failures.push(`helper plist validation failed: ${file}: ${error.message}`); }
}

export function validateWorkspace({ release = false, bundle = null } = {}) {
  const failures = [];
  const packageJson = readPackage();
  const info = versionInfo();
  add(failures, packageJson.name === "microgravity", "package name must be microgravity");
  add(failures, packageJson.license === "GPL-3.0-only", "package license must be GPL-3.0-only");
  add(failures, packageJson.engines?.node === ">=24.13", "Node engine must be >=24.13");
  try { syncVersion({ check: true }); } catch (error) { failures.push(error.message); }

  const baseConfig = fs.readFileSync(path.join(root, "config/base.xcconfig"), "utf8");
  add(failures, baseConfig.includes(`PRODUCT_BUNDLE_IDENTIFIER = ${bundleIdentifier}`), "bundle ID must be run.rosie.microgravity");
  add(failures, baseConfig.includes("MACOSX_DEPLOYMENT_TARGET = 14.0"), "minimum macOS version must be 14.0");
  add(failures, baseConfig.includes("SWIFT_VERSION = 5.8"), "Swift language compatibility must be 5.8");
  add(failures, baseConfig.includes("-lsqlite3"), "app must link SQLite3");

  const infoPlist = fs.readFileSync(path.join(root, "Info.plist"), "utf8");
  const versionConfig = fs.readFileSync(path.join(root, "config/version.xcconfig"), "utf8");
  add(failures, infoPlist.includes("$(PRODUCT_BUNDLE_IDENTIFIER)"), "Info.plist bundle identity must come from build settings");
  add(failures, infoPlist.includes("$(MARKETING_VERSION)") && infoPlist.includes("$(CURRENT_PROJECT_VERSION)"), "Info.plist version fields must come from package.json version metadata");
  add(failures, new RegExp(`<key>CFBundleIconName</key>\\s*<string>${appIconName}</string>`).test(infoPlist), `Info.plist must declare CFBundleIconName ${appIconName}`);
  add(failures, infoPlist.includes("$(SPARKLE_PUBLIC_KEY)"), "Info.plist must use the configured Sparkle public key");
  add(failures, infoPlist.includes("$(SPARKLE_ENABLE_AUTOMATIC_CHECKS)"), "Sparkle automatic checks must be controlled by build configuration");
  add(failures, versionConfig.includes("SPARKLE_ENABLE_AUTOMATIC_CHECKS = NO"), "Sparkle automatic checks must default off until a public key is configured");
  add(failures, versionConfig.includes("SPARKLE_PUBLIC_KEY = $(MICROGRAVITY_SPARKLE_PUBLIC_KEY)"), "Sparkle public key must come from Microgravity environment configuration");
  const feedValue = versionConfig.match(/^SPARKLE_FEED_URL\s*=(.*)$/m)?.[1]?.trim() ?? "";
  add(failures, feedValue !== "" && !feedValue.includes("//"), "SPARKLE_FEED_URL must escape // so xcconfig does not truncate it");
  add(failures, /^https:\/\/github\.com\/BurntToasters\/Microgravity\/releases\/latest\/download\/appcast(?:-beta)?\.xml$/.test(feedValue.replaceAll("$()", "")), "SPARKLE_FEED_URL must decode to a GitHub releases appcast URL");
  add(failures, fs.existsSync(path.join(root, "Microgravity.entitlements")), "app entitlements file is missing");
  add(failures, fs.existsSync(path.join(root, "MicrogravityHelper.entitlements")), "helper entitlements file is missing");

  checkHelperPlist(path.join(root, "resources/helper/run.rosie.microgravity.helper.plist"), failures);
  const upstreamPath = path.join(root, "vendor/Sparkle/UPSTREAM");
  const upstream = fs.existsSync(upstreamPath) ? fs.readFileSync(upstreamPath, "utf8") : "";
  const upstreamFields = Object.fromEntries([...upstream.matchAll(/^([A-Z0-9_]+)=(.*)$/gm)].map((match) => [match[1], match[2]]));
  const pinPath = path.join(root, "sparkle_pin.yml");
  const pinText = fs.existsSync(pinPath) ? fs.readFileSync(pinPath, "utf8") : "";
  const pin = Object.fromEntries([...pinText.matchAll(/^([a-z0-9_]+):\s*["']?([^"'\s#]+)/gm)].map((match) => [match[1], match[2]]));
  add(failures, /^[0-9]+\.[0-9]+\.[0-9]+$/.test(pin.version ?? "") && /^[0-9]+$/.test(pin.build ?? "") && /^[a-f0-9]{40}$/.test(pin.commit ?? "") && /^[a-f0-9]{64}$/.test(pin.tarball_sha256 ?? ""), "sparkle_pin.yml must pin version, build, commit, and tarball_sha256");
  const sparkleVersion = upstreamFields.VERSION;
  add(failures, sparkleVersion === pin.version, `vendored Sparkle must be the pinned version ${pin.version}; run ./get_sparkle.sh`);
  add(failures, upstreamFields.COMMIT === pin.commit && upstreamFields.SHA256 === pin.tarball_sha256, "vendor/Sparkle/UPSTREAM commit and SHA-256 must match sparkle_pin.yml; run ./get_sparkle.sh");
  add(failures, upstreamFields.SOURCE === `https://github.com/sparkle-project/Sparkle/releases/download/${pin.version}/Sparkle-${pin.version}.tar.xz`, "Sparkle provenance must point to the pinned upstream release archive");
  const sparklePackagePath = path.join(root, "vendor/Sparkle/Package.swift");
  const sparklePackage = fs.existsSync(sparklePackagePath) ? fs.readFileSync(sparklePackagePath, "utf8") : "";
  const packageSparkleVersion = sparklePackage.match(/MARKETING_VERSION[^\n]*?([0-9]+\.[0-9]+\.[0-9]+)/)?.[1];
  const packageSparkleBuild = sparklePackage.match(/CURRENT_PROJECT_VERSION[^\n]*?([0-9]+)/)?.[1];
  const helperInfoPath = path.join(root, "vendor/Sparkle/Helpers/Updater.app/Contents/Info.plist");
  const helperInfo = fs.existsSync(helperInfoPath) ? fs.readFileSync(helperInfoPath, "utf8") : "";
  const helperSparkleVersion = helperInfo.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
  const helperSparkleBuild = helperInfo.match(/<key>CFBundleVersion<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
  add(failures, packageSparkleVersion === sparkleVersion && helperSparkleVersion === sparkleVersion, "Sparkle package source and bundled Updater helper versions must match upstream");
  add(failures, !!packageSparkleBuild && packageSparkleBuild === helperSparkleBuild, "Sparkle package source and bundled Updater helper build numbers must match");
  add(failures, fs.existsSync(path.join(root, "resources/licenses/Sparkle-LICENSE.txt")), "Sparkle license notices are missing");

  const projectPath = path.join(root, "Microgravity.xcodeproj/project.pbxproj");
  if (fs.existsSync(projectPath)) {
    failures.push(...checkProject(fs.readFileSync(projectPath, "utf8")));
    if (process.platform === "darwin") {
      for (const file of ["Info.plist", "Microgravity.entitlements", "MicrogravityHelper.entitlements", "Microgravity.xcodeproj/project.pbxproj"]) {
        try { run("plutil", ["-lint", file], { capture: true }); } catch (error) { failures.push(error.message); }
      }
    }
  } else failures.push("Microgravity.xcodeproj/project.pbxproj is missing");

  const sources = discoverSources();
  add(failures, sources.app.length > 0, "app has no Swift sources under its synchronized source roots");
  add(failures, sources.helper.length > 0, "helper has no Swift sources under Sources/Helper or Sources/Shared");

  if (release) failures.push(...releaseSettingsFailures());
  if (bundle) {
    try {
      add(failures, bundleValue(bundle, "CFBundleIdentifier") === bundleIdentifier, "built app bundle ID does not match Microgravity");
      add(failures, bundleValue(bundle, "CFBundleShortVersionString") === info.version, "built app marketing version does not match package.json");
      add(failures, bundleValue(bundle, "CFBundleVersion") === String(info.buildNumber), "built app build number does not match package.json");
      const sparkleFramework = path.join(bundle, "Contents/Frameworks/Sparkle.framework");
      add(failures, fs.existsSync(sparkleFramework), "built app is missing Sparkle.framework");
      add(failures, fs.existsSync(path.join(sparkleFramework, "Versions/A/Autoupdate")), "built app is missing Sparkle Autoupdate helper");
      add(failures, fs.existsSync(path.join(sparkleFramework, "Versions/A/Updater.app")), "built app is missing Sparkle Updater helper");
      add(failures, fs.existsSync(path.join(bundle, "Contents/Helpers/MicrogravityHelper")), "built app is missing its helper executable");
      checkHelperPlist(path.join(bundle, "Contents/Library/LaunchDaemons/run.rosie.microgravity.helper.plist"), failures);
      add(failures, bundleValue(bundle, "CFBundleIconName") === appIconName, `built app CFBundleIconName must be ${appIconName}`);
      const assetCatalog = path.join(bundle, "Contents/Resources/Assets.car");
      const assetEntries = fs.existsSync(assetCatalog) ? JSON.parse(run("xcrun", ["assetutil", "--info", assetCatalog], { capture: true }).stdout) : [];
      add(failures, assetEntries.some((entry) => entry.AssetType === "Icon Image" && entry.Name === appIconName), `built app Assets.car has no ${appIconName} app icon`);
      const automaticChecks = bundleValue(bundle, "SUEnableAutomaticChecks").toLowerCase();
      const sparkleKey = bundleValue(bundle, "SUPublicEDKey");
      if (!sparkleKey) add(failures, automaticChecks === "no" || automaticChecks === "false", "automatic Sparkle checks must be disabled when no public key is configured");
      if (release) {
        add(failures, !!sparkleKey, "release app must contain a configured Sparkle public key");
        add(failures, sparkleKey === process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY, "release app Sparkle public key must match the configured key");
      }
    } catch (error) {
      failures.push(`bundle validation failed: ${error.message}`);
    }
  }

  if (failures.length) throw new Error(`workspace validation failed:\n- ${failures.join("\n- ")}`);
  return { version: info.version, buildNumber: info.buildNumber };
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    validateWorkspace({ release: process.argv.includes("--release") });
    console.log("validate: ok");
  } catch (error) {
    console.error(`validate: FAILED:\n${error.message}`);
    process.exit(1);
  }
}
