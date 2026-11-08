import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { discoverSources, renderProject } from "../generate-project.mjs";
import { buildNumberFailures, validateRepositoryState, sparkleCredentialSources } from "../release-preflight.mjs";
import { gpgSigningInvocation, sparkleSigningInvocation } from "../release.mjs";
import { childEnvironment, root, versionInfo } from "../lib/core.mjs";
import { checkProject, releaseSettingsFailures } from "../validate.mjs";
import { appcastFilename, renderAppcast } from "../lib/appcast.mjs";
import { expectedChangelog } from "../lib/changelog.mjs";
import { expectedPackageLock, sparkleFeedValue } from "../sync-version.mjs";
import { validateRecord, sessionHours } from "../release-session.mjs";

function temporaryProject(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "microgravity-project-"));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  for (const [directory, filename] of [
    ["Sources/App", "App.swift"],
    ["Sources/Core", "Model.swift"],
    ["Sources/Shared", "Shared.swift"],
    ["Sources/Helper", "main.swift"],
    ["Tests/CoreTests", "ModelTests.swift"],
    ["Tests/UITests", "LaunchTests.swift"],
  ]) {
    fs.mkdirSync(path.join(base, directory), { recursive: true });
    fs.writeFileSync(path.join(base, directory, filename), "// fixture\n");
  }
  return base;
}

test("project discovery assigns new app, helper, shared, core-test, and UI-test files", (t) => {
  const base = temporaryProject(t);
  fs.writeFileSync(path.join(base, "Sources/Core/NewType.swift"), "// discovered later\n");
  const sources = discoverSources(base);
  assert.deepEqual(sources.app, [
    "Sources/App/App.swift",
    "Sources/Core/Model.swift",
    "Sources/Core/NewType.swift",
    "Sources/Shared/Shared.swift",
  ]);
  assert.deepEqual(sources.helper, ["Sources/Helper/main.swift", "Sources/Shared/Shared.swift"]);
  assert.deepEqual(sources.coreTests, ["Tests/CoreTests/ModelTests.swift"]);
  assert.deepEqual(sources.uiTests, ["Tests/UITests/LaunchTests.swift"]);
});

test("generated Xcode project is deterministic and includes all test hosts", (t) => {
  const base = temporaryProject(t);
  const first = renderProject(base);
  assert.equal(renderProject(base), first);
  for (const fragment of [
    "Microgravity.app",
    "MicrogravityHelper",
    "MicrogravityCoreTests.xctest",
    "MicrogravityUITests.xctest",
    "Sources/Core",
    "Sources/Shared",
    "Tests/CoreTests",
    "Tests/UITests",
  ]) assert.ok(first.includes(fragment), `missing generated project entry: ${fragment}`);
});

test("checked-in Xcode project has complete synchronized target membership and references", () => {
  const project = fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "../../Microgravity.xcodeproj/project.pbxproj"), "utf8");
  assert.deepEqual(checkProject(project), []);
});

test("release repository validation rejects forks, wrong branch, dirty trees, and moved remote heads", () => {
  const state = {
    version: "0.1.0",
    branch: "main",
    origin: "https://github.com/BurntToasters/Microgravity.git",
    status: " M Sources/App/App.swift",
    head: "abc",
    remoteHead: "def",
    upstream: "origin/main",
  };
  assert.deepEqual(validateRepositoryState({ ...state, status: "", remoteHead: "abc" }), []);
  assert.ok(validateRepositoryState({ ...state, origin: "https://github.com/example/fork.git" }).some((failure) => failure.includes("origin")));
  assert.ok(validateRepositoryState({ ...state, branch: "beta" }).some((failure) => failure.includes("branch")));
  assert.ok(validateRepositoryState(state).some((failure) => failure.includes("clean")));
  assert.ok(validateRepositoryState({ ...state, status: "", remoteHead: "def" }).some((failure) => failure.includes("HEAD")));
  assert.ok(validateRepositoryState({ ...state, status: "", remoteHead: "abc", tagHead: "def" }).some((failure) => failure.includes("tag")));
  assert.ok(validateRepositoryState({ ...state, status: "", remoteHead: "abc", draftTarget: "def" }).some((failure) => failure.includes("draft")));
});

test("release build numbers must advance and exactly one Sparkle signing source is accepted", () => {
  assert.deepEqual(buildNumberFailures(2, { "v0.1.0": 1, "v0.0.9": 0 }), []);
  assert.deepEqual(buildNumberFailures(1, { "v0.1.0": 1 }), ["buildNumber 1 must be higher than v0.1.0's 1, or Sparkle will not offer the update"]);
  assert.throws(() => sparkleSigningInvocation("archive.zip", { environment: {} }), /exactly one/);
  assert.throws(() => sparkleSigningInvocation("archive.zip", { environment: {
    MICROGRAVITY_SPARKLE_ACCOUNT: "account",
    MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE: "/private/key",
  } }), /exactly one/);
  const invocation = sparkleSigningInvocation("archive.zip", { environment: { MICROGRAVITY_SPARKLE_PRIVATE_KEY: "private-material" } });
  assert.deepEqual(invocation.args, ["--ed-key-file", "-", "archive.zip"]);
  assert.equal(invocation.input, "private-material\n");
});

test("signing passphrases travel over stdin and secret environment values are stripped from generic children", () => {
  const invocation = gpgSigningInvocation("archive.zip", "archive.zip.asc", {
    MICROGRAVITY_GPG_KEY: "release-key",
    MICROGRAVITY_GPG_PASSPHRASE: "private-passphrase",
  });
  assert.ok(invocation.args.includes("release-key"));
  assert.ok(!invocation.args.includes("private-passphrase"));
  assert.equal(invocation.input, "private-passphrase\n");
  const child = childEnvironment({
    MICROGRAVITY_GPG_PASSPHRASE: "private-passphrase",
    MICROGRAVITY_SPARKLE_ACCOUNT: "private-account@example.invalid",
    MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE: "/private/key",
    GITHUB_TOKEN: "token",
    CI: "true",
  });
  assert.equal(child.MICROGRAVITY_GPG_PASSPHRASE, undefined);
  assert.equal(child.MICROGRAVITY_SPARKLE_ACCOUNT, undefined);
  assert.equal(child.MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE, undefined);
  assert.equal(child.GITHUB_TOKEN, undefined);
  assert.equal(child.CI, "true");
  assert.equal(childEnvironment({ CI: "true" }).CI, "true");
});

test("version synchronization updates both lockfile identity fields and refuses a missing changelog heading", () => {
  const lock = JSON.stringify({ version: "0.0.1", packages: { "": { version: "0.0.1" }, nested: { version: "8.0.0" } } });
  const updated = JSON.parse(expectedPackageLock(lock, "0.1.0"));
  assert.equal(updated.version, "0.1.0");
  assert.equal(updated.packages[""].version, "0.1.0");
  assert.equal(updated.packages.nested.version, "8.0.0");
  const fresh = expectedChangelog("# Microgravity changelog\n\n", "0.1.0");
  assert.match(fresh, /^# Microgravity changelog\n\n<!-- downloads:start[^\n]*-->\n# ⬇️ Downloads\n[\s\S]*\/download\/v0\.1\.0\/Microgravity-0\.1\.0\.zip[\s\S]*<!-- downloads:end -->\n\n## 0\.1\.0\n\nRelease notes pending\.\n/);
  assert.equal(expectedChangelog(fresh, "0.1.0"), fresh);
  const bumped = expectedChangelog(fresh, "0.2.0-beta.1");
  assert.match(bumped, /This is a Beta build[\s\S]*\/download\/v0\.2\.0-beta\.1\/Microgravity-0\.2\.0-beta\.1\.zip[\s\S]*<!-- downloads:end -->\n\n## 0\.2\.0-beta\.1\n\nRelease notes pending\.\n\n## 0\.1\.0\n/);
  assert.doesNotMatch(bumped, /\/download\/v0\.1\.0\//);
  assert.throws(() => expectedChangelog("Wrong title\n", "0.1.0"), /must start/);
  const packageJson = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  assert.deepEqual(versionInfo(), { version: packageJson.version, buildNumber: packageJson.buildNumber, channel: packageJson.version.includes("-beta.") ? "beta" : "stable", tag: `v${packageJson.version}` });
});

test("Sparkle feed URL escapes // for xcconfig and decodes to the channel appcast", () => {
  const stable = sparkleFeedValue("0.1.0");
  const beta = sparkleFeedValue("0.1.0-beta.2");
  assert.equal(stable, "https:/$()/github.com/BurntToasters/Microgravity/releases/latest/download/appcast.xml");
  assert.equal(beta, "https:/$()/github.com/BurntToasters/Microgravity/releases/latest/download/appcast-beta.xml");
  for (const value of [stable, beta]) {
    assert.equal(value.includes("//"), false);
    assert.match(value, /^https:\/\$\(\)\/github\.com\//);
  }
  assert.equal(stable.replaceAll("$()", ""), "https://github.com/BurntToasters/Microgravity/releases/latest/download/appcast.xml");
  assert.equal(beta.replaceAll("$()", ""), "https://github.com/BurntToasters/Microgravity/releases/latest/download/appcast-beta.xml");
  assert.equal(fs.readFileSync(path.join(root, "config/version.xcconfig"), "utf8").includes(`SPARKLE_FEED_URL = ${stable}\n`), true);
});

test("appcast selects the correct channel feed and binds the version, build, size, and archive signature", () => {
  assert.equal(appcastFilename("stable"), "appcast.xml");
  assert.equal(appcastFilename("beta"), "appcast-beta.xml");
  const xml = renderAppcast({ version: "0.1.0", buildNumber: 1, tag: "v0.1.0" }, {
    signature: "signature-value",
    length: 123,
    notes: "one release note",
    publishedAt: new Date("2026-11-03T00:00:00.000Z"),
  });
  assert.match(xml, /Microgravity-0\.1\.0\.zip/);
  assert.match(xml, /sparkle:version="1"/);
  assert.match(xml, /length="123"/);
  assert.match(xml, /sparkle:edSignature="signature-value"/);
  assert.match(xml, /<description sparkle:format="markdown"><!\[CDATA\[one release note\]\]><\/description>/);
  assert.doesNotMatch(xml, /releaseNotesLink/, "a release notes link makes Sparkle show the whole GitHub page");
});

test("appcast embeds Markdown notes safely and requires them", () => {
  const render = (notes) => renderAppcast({ version: "0.1.1", buildNumber: 2, tag: "v0.1.1" }, {
    signature: "s", length: 1, notes, publishedAt: new Date("2026-11-08T00:00:00.000Z"),
  });
  assert.match(render("## 0.1.1\n\n- a <b>]]> c"),
    /<description sparkle:format="markdown"><!\[CDATA\[## 0\.1\.1\n\n- a <b>\]\]\]\]><!\[CDATA\[> c\]\]><\/description>/);
  assert.throws(() => render("  "), /notes/);
  assert.throws(() => render(undefined), /notes/);
});

test("release sessions expire and bind all current build identity fields", () => {
  const now = Date.now();
  const identity = { version: "0.1.0", branch: "main", commit: "abc", buildNumber: 1 };
  const current = { schema: 1, createdAt: new Date(now - 1000).toISOString(), identity };
  assert.equal(validateRecord(current, identity, now), current);
  const expired = { ...current, createdAt: new Date(now - sessionHours * 60 * 60 * 1000 - 1).toISOString() };
  assert.throws(() => validateRecord(expired, identity, now), /expired/);
  assert.throws(() => validateRecord(current, { ...identity, commit: "def" }, now), /does not match/);
});

test("Sparkle release credentials use Microgravity-only names and reveal no credential values", () => {
  assert.deepEqual(sparkleCredentialSources({
    MICROGRAVITY_SPARKLE_ACCOUNT: "account",
    MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE: "/private/key",
    FOREIGN_SPARKLE_PRIVATE_KEY: "must-not-be-used",
  }), ["MICROGRAVITY_SPARKLE_ACCOUNT", "MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE"]);
});

test("release validation blocks without a real update key, Apple identity, notarization profile, and GPG key", () => {
  const failures = releaseSettingsFailures({});
  for (const name of ["MICROGRAVITY_SPARKLE_PUBLIC_KEY", "MICROGRAVITY_SIGNING_IDENTITY", "MICROGRAVITY_TEAM_ID", "MICROGRAVITY_NOTARY_PROFILE", "MICROGRAVITY_GPG_KEY"]) {
    assert.ok(failures.some((failure) => failure.includes(name)));
  }
  assert.ok(failures.some((failure) => failure.includes("exactly one Sparkle signing credential")));
});

test("release artifacts are bound to exact contents and session", async (t) => {
  const { createArtifactManifest, validateArtifactManifest } = await import("../release-session.mjs");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mg-artifacts-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const paths = ["archive.zip", "feed.xml", "SHA256SUMS", "archive.zip.asc"].map((name) => path.join(dir, name));
  paths.forEach((file) => fs.writeFileSync(file, path.basename(file)));
  const session = { createdAt: "2026-01-01T00:00:00Z", identity: { commit: "abc" } };
  const manifest = createArtifactManifest(session, paths);
  assert.doesNotThrow(() => validateArtifactManifest(manifest, session, dir, paths.map((file) => path.basename(file))));
  fs.writeFileSync(paths[0], "substituted archive");
  assert.throws(() => validateArtifactManifest(manifest, session, dir, paths.map((file) => path.basename(file))), /mismatch/);
  assert.throws(() => validateArtifactManifest(manifest, { ...session, createdAt: "2026-01-02T00:00:00Z" }, dir, paths.map((file) => path.basename(file))), /session/);
});

test("release source tree hash includes executable modes", async (t) => {
  const { treeHash } = await import("../lib/core.mjs");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mg-modes-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "script");
  fs.writeFileSync(file, "same");
  fs.chmodSync(file, 0o644);
  const before = treeHash(["script"], dir);
  fs.chmodSync(file, 0o755);
  assert.notEqual(treeHash(["script"], dir), before);
});

test("Sparkle archive verification rejects a different configured public key", async (t) => {
  const crypto = await import("node:crypto");
  const { verifySparkleArchive } = await import("../release.mjs");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mg-sparkle-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "archive.zip");
  fs.writeFileSync(file, "archive contents");
  const signer = crypto.generateKeyPairSync("ed25519");
  const other = crypto.generateKeyPairSync("ed25519");
  const rawPublic = (key) => key.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
  const signature = crypto.sign(null, fs.readFileSync(file), signer.privateKey).toString("base64");
  assert.doesNotThrow(() => verifySparkleArchive(file, signature, rawPublic(signer.publicKey)));
  assert.throws(() => verifySparkleArchive(file, signature, rawPublic(other.publicKey)), /does not match/);
});

test("helper daemon plist requires the expected identity, program, and Mach service", async () => {
  const { helperPlistFailures } = await import("../validate.mjs");
  const good = { Label: "run.rosie.microgravity.helper", BundleProgram: "Contents/Helpers/MicrogravityHelper", MachServices: { "run.rosie.microgravity.helper": true } };
  assert.deepEqual(helperPlistFailures(good), []);
  assert.equal(helperPlistFailures({ ...good, Label: "other" }).length, 1);
  assert.equal(helperPlistFailures({ ...good, BundleProgram: "/tmp/untrusted" }).length, 1);
  assert.equal(helperPlistFailures({ ...good, MachServices: {} }).length, 1);
});

test("GPG verification rejects another trusted key and ambiguous configured keys", async () => {
  const { assertConfiguredGpgSigner } = await import("../release.mjs");
  const listing = "pub:::::::::\nfpr:::::::::PRIMARY:\nsub:::::::::\nfpr:::::::::SUBKEY:\n";
  assert.doesNotThrow(() => assertConfiguredGpgSigner(listing, "[GNUPG:] VALIDSIG SUBKEY 2026-01-01"));
  assert.throws(() => assertConfiguredGpgSigner(listing, "[GNUPG:] VALIDSIG OTHER 2026-01-01"), /not from configured key/);
  assert.throws(() => assertConfiguredGpgSigner(listing + "pub:::::::::\n", "[GNUPG:] VALIDSIG SUBKEY"), /exactly one/);
});

test("helper signing uses explicit daemon identity and retains hardened runtime", async () => {
  const { releaseCodesignArguments } = await import("../build.mjs");
  const args = releaseCodesignArguments("/tmp/helper", { identity: "Developer ID", identifier: "run.rosie.microgravity.helper" });
  assert.deepEqual(args.slice(args.indexOf("--identifier"), args.indexOf("--identifier") + 2), ["--identifier", "run.rosie.microgravity.helper"]);
  assert.ok(args.includes("runtime"));
});

test("Debug project builds app and hosted tests for the active architecture", () => {
  const project = renderProject();
  const debug = project.match(/\/\* Project Debug \*\/ = \{isa = XCBuildConfiguration; buildSettings = \{([^}]*)\}/)?.[1] ?? "";
  assert.match(debug, /ONLY_ACTIVE_ARCH = YES/);
});

test("release prepare skips the UI automation suite unless MICROGRAVITY_RELEASE_UI_TESTS=1", async () => {
  const { releaseTestArguments } = await import("../release.mjs");
  assert.deepEqual(releaseTestArguments({}), ["--", "--skip-ui"]);
  assert.deepEqual(releaseTestArguments({ MICROGRAVITY_RELEASE_UI_TESTS: "0" }), ["--", "--skip-ui"]);
  assert.deepEqual(releaseTestArguments({ MICROGRAVITY_RELEASE_UI_TESTS: "1" }), []);
});

test("GitHub release title is the version tag without the app name", async () => {
  const { expectedDraftTarget } = await import("../release.mjs");
  assert.equal(expectedDraftTarget({ tag: "v0.1.1", version: "0.1.1", channel: "stable" }, "abc").title, "v0.1.1");
  assert.equal(expectedDraftTarget({ tag: "v0.2.0-beta.1", version: "0.2.0-beta.1", channel: "beta" }, "abc").title, "v0.2.0-beta.1");
});
