import fs from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { appcastFilename, writeAppcast } from "./lib/appcast.mjs";
import { releaseNotes as formatReleaseNotes } from "./lib/changelog.mjs";
import { output, repository, repositoryUrl, root, run, sha256File, versionInfo } from "./lib/core.mjs";
import { buildRelease } from "./build.mjs";
import { runPreflight, sparkleCredentialSources } from "./release-preflight.mjs";
import { artifactManifestPath, createArtifactManifest, createSession, validateArtifactManifest, verifySession } from "./release-session.mjs";

function ghResult(args) {
  return run("gh", args, { capture: true, allowFailure: true });
}

function ghRun(args) {
  return run("gh", args);
}

function ghOutput(args) {
  return output("gh", args);
}

export function expectedDraftTarget(info, commit) {
  return { tag: info.tag, target: commit, title: `Microgravity ${info.version}`, prerelease: info.channel === "beta" };
}

export function betaMirrorTarget(channel, latestStableTag) {
  if (channel !== "beta") return null;
  if (!latestStableTag) throw new Error("beta feed mirroring requires a public stable release");
  return latestStableTag;
}

export function feedFilenames(channel) {
  return [appcastFilename(channel)];
}

function ensureDraft(info, commit) {
  const result = ghResult(["release", "view", info.tag, "--repo", repository, "--json", "isDraft,targetCommitish"]);
  if (result.status === 0) {
    const release = JSON.parse(result.stdout);
    if (!release.isDraft) throw new Error(`${info.tag} is already published.`);
    if (![commit, info.channel === "beta" ? "beta" : "main"].includes(release.targetCommitish)) throw new Error(`${info.tag} draft targets ${release.targetCommitish}, not this release commit.`);
    return;
  }
  const draft = expectedDraftTarget(info, commit);
  const args = ["release", "create", draft.tag, "--repo", repository, "--draft", "--target", draft.target, "--title", draft.title, "--notes", `Microgravity ${info.version} release. See the tagged source and bundled notices for the corresponding GPL source and licensing information.`];
  if (draft.prerelease) args.push("--prerelease");
  ghRun(args);
}

export function sparkleSigningInvocation(file, { printOnly = false, verify = false, signature = null, environment = process.env } = {}) {
  const sources = sparkleCredentialSources(environment);
  if (sources.length !== 1) throw new Error("Sparkle signing requires exactly one configured credential source.");
  const args = [];
  if (verify) args.push("--verify");
  let input;
  if (environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY) {
    args.push("--ed-key-file", "-");
    input = environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY.endsWith("\n") ? environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY : `${environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY}\n`;
  } else if (environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE) {
    args.push("--ed-key-file", path.resolve(root, environment.MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE));
  } else {
    args.push("--account", environment.MICROGRAVITY_SPARKLE_ACCOUNT);
  }
  if (printOnly) args.push("-p");
  args.push(file);
  if (signature) args.push(signature);
  return { args, input };
}

function signSparkle(file, printOnly = false) {
  const tool = path.join(root, "vendor/Sparkle/bin/sign_update");
  const invocation = sparkleSigningInvocation(file, { printOnly });
  return output(tool, invocation.args, { input: invocation.input }).trim();
}

export function verifySparkleArchive(file, signature, publicKey = process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY) {
  const raw = Buffer.from(publicKey ?? "", "base64");
  const sig = Buffer.from(signature, "base64");
  if (raw.length !== 32 || raw.toString("base64") !== publicKey || sig.length !== 64 || sig.toString("base64") !== signature)
    throw new Error("invalid Sparkle public key or archive signature");
  const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]), format: "der", type: "spki" });
  if (!crypto.verify(null, fs.readFileSync(file), key, sig)) throw new Error("Sparkle archive signature does not match configured public key");
}

function verifySparkleFeed(file) {
  const tool = path.join(root, "vendor/Sparkle/bin/sign_update");
  const invocation = sparkleSigningInvocation(file, { verify: true });
  run(tool, invocation.args, { input: invocation.input });
}

export function gpgSigningInvocation(file, signature, environment = process.env) {
  const args = ["--batch", "--yes"];
  let input;
  if (environment.MICROGRAVITY_GPG_PASSPHRASE) {
    args.push("--pinentry-mode", "loopback", "--passphrase-fd", "0");
    input = environment.MICROGRAVITY_GPG_PASSPHRASE.endsWith("\n") ? environment.MICROGRAVITY_GPG_PASSPHRASE : `${environment.MICROGRAVITY_GPG_PASSPHRASE}\n`;
  }
  args.push("--armor", "--detach-sign", "--local-user", environment.MICROGRAVITY_GPG_KEY, "--output", signature, file);
  return { args, input };
}

function signGpg(file) {
  const signature = `${file}.asc`;
  fs.rmSync(signature, { force: true });
  const invocation = gpgSigningInvocation(file, signature);
  run("gpg", invocation.args, { input: invocation.input });
  return signature;
}

function writeChecksums(files, destination) {
  const contents = files.map((file) => `${sha256File(file)}  ${path.basename(file)}`).join("\n");
  fs.writeFileSync(destination, `${contents}\n`);
  return destination;
}

function prepare() {
  runPreflight({ release: true });
  run("npm", ["run", "test:all"]);
  createSession();
  console.log("release:prepare: ok (24-hour session recorded)");
}

function continueRelease() {
  const session = verifySession();
  runPreflight({ release: true });
  const info = versionInfo();
  ensureDraft(info, session.identity.commit);
  const { zip } = buildRelease();
  const signature = signSparkle(zip, true);
  verifySparkleArchive(zip, signature);
  const notes = formatReleaseNotes(info, fs.readFileSync(path.join(root, "CHANGELOG.md"), "utf8"));
  const appcast = writeAppcast(path.dirname(zip), { info, signature, length: fs.statSync(zip).size, notes });
  signSparkle(appcast);
  const checksums = writeChecksums([zip, appcast], path.join(path.dirname(zip), "SHA256SUMS"));
  const assets = [zip, appcast, checksums];
  assets.push(...assets.map(signGpg));
  for (const file of [zip, appcast, checksums]) verifyGpg(file);
  verifySparkleFeed(appcast);
  verifyChecksums([zip, appcast], checksums);
  const manifest = createArtifactManifest(session, assets);
  fs.writeFileSync(artifactManifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  validateArtifactManifest(manifest, session, path.dirname(zip), assets.map((file) => path.basename(file)));
  ghRun(["release", "upload", info.tag, "--repo", repository, "--clobber", ...assets]);
  const notesFile = path.join(path.dirname(zip), "RELEASE_NOTES.md");
  fs.writeFileSync(notesFile, `${notes}\n`);
  ghRun(["release", "edit", info.tag, "--repo", repository, "--notes-file", notesFile]);
  console.log(`release:mac:continue: draft uploaded (${assets.map((asset) => path.basename(asset)).join(", ")})`);
}

function publish() {
  const session = verifySession();
  const info = runPreflight({ release: true });
  const names = [`Microgravity-${info.version}.zip`, appcastFilename(info.channel), "SHA256SUMS"];
  const expected = [...names, ...names.map((name) => `${name}.asc`)];
  const manifest = JSON.parse(fs.readFileSync(artifactManifestPath, "utf8"));
  validateArtifactManifest(manifest, session, path.join(root, "dist"), expected);
  const downloaded = fs.mkdtempSync(path.join(os.tmpdir(), "microgravity-draft-"));
  try {
    ghRun(["release", "download", info.tag, "--repo", repository, "--dir", downloaded]);
    validateArtifactManifest(manifest, session, downloaded, expected);
    const actual = fs.readdirSync(downloaded).sort();
    if (JSON.stringify(actual) !== JSON.stringify([...expected].sort())) throw new Error("draft contains unexpected or missing assets");
  } finally { fs.rmSync(downloaded, { recursive: true, force: true }); }
  ghRun(["release", "edit", info.tag, "--repo", repository, "--draft=false", ...(info.channel === "beta" ? ["--prerelease"] : ["--latest"])]);
  if (info.channel === "beta") {
    const feed = path.join(root, "dist", appcastFilename("beta"));
    if (!fs.existsSync(feed)) throw new Error("beta appcast is missing from the prepared release assets.");
    if (!fs.readFileSync(feed, "utf8").includes(`Microgravity-${info.version}.zip`)) throw new Error(`prepared beta appcast does not describe ${info.tag}.`);
    const stableTag = ghOutput(["release", "view", "--repo", repository, "--json", "tagName", "--jq", ".tagName"]);
    const mirror = betaMirrorTarget(info.channel, stableTag);
    ghRun(["release", "upload", mirror, "--repo", repository, "--clobber", feed, signGpg(feed)]);
  }
  console.log(`release:publish: ok (${info.tag})`);
}

export function assertConfiguredGpgSigner(keyListing, verificationStatus) {
  const lines = keyListing.split("\n");
  if (lines.filter((line) => line.startsWith("pub:")).length !== 1) throw new Error("configured GPG key must resolve to exactly one primary key");
  const fingerprints = lines.filter((line) => line.startsWith("fpr:")).map((line) => line.split(":")[9]?.toUpperCase()).filter(Boolean);
  const valid = verificationStatus.split("\n").find((line) => line.startsWith("[GNUPG:] VALIDSIG "))?.split(" ");
  if (!fingerprints.length || !valid || !fingerprints.includes(valid[2]?.toUpperCase())) throw new Error("GPG signature is not from configured key");
}

function verifyGpg(file, signature = `${file}.asc`) {
  if (!fs.existsSync(file) || !fs.existsSync(signature)) throw new Error(`published asset or GPG signature missing: ${path.basename(file)}`);
  const keys = output("gpg", ["--batch", "--with-colons", "--fingerprint", "--fingerprint", "--list-keys", process.env.MICROGRAVITY_GPG_KEY]);
  const result = run("gpg", ["--batch", "--status-fd", "1", "--verify", signature, file], { capture: true });
  assertConfiguredGpgSigner(keys, String(result.stdout));
}

function verifyChecksums(files, checksumFile) {
  const expected = new Map(fs.readFileSync(checksumFile, "utf8").trim().split("\n").map((line) => {
    const [hash, filename] = line.split(/\s+/, 2);
    return [filename, hash];
  }));
  for (const file of files) {
    if (expected.get(path.basename(file)) !== sha256File(file)) throw new Error(`published checksum mismatch: ${path.basename(file)}`);
  }
}

async function verifyLiveFeed(info, directory, attempts = 6) {
  const feedName = appcastFilename(info.channel);
  const url = `${repositoryUrl}/releases/latest/download/${feedName}`;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(15_000) });
    if (response.ok) {
      const contents = await response.text();
      if (contents.includes(`sparkle:version="${info.buildNumber}"`)) {
        const liveFeed = path.join(directory, `live-${feedName}`);
        fs.writeFileSync(liveFeed, contents);
        verifySparkleFeed(liveFeed);
        return;
      }
    }
    if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, 10_000));
  }
  throw new Error(`${url} does not offer build ${info.buildNumber} yet; installed copies will not see ${info.tag}`);
}

async function verifyPublished() {
  const info = versionInfo();
  const release = JSON.parse(ghOutput(["release", "view", info.tag, "--repo", repository, "--json", "isDraft,isPrerelease"]));
  if (release.isDraft) throw new Error(`${info.tag} is still a draft`);
  if (release.isPrerelease !== (info.channel === "beta")) throw new Error(`${info.tag} prerelease flag does not match the ${info.channel} channel`);
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "microgravity-release-"));
  try {
    ghRun(["release", "download", info.tag, "--repo", repository, "--dir", temp]);
    const zip = path.join(temp, `Microgravity-${info.version}.zip`);
    const appcast = path.join(temp, appcastFilename(info.channel));
    const checksums = path.join(temp, "SHA256SUMS");
    for (const file of [zip, appcast, checksums]) verifyGpg(file);
    verifyChecksums([zip, appcast], checksums);
    const xml = fs.readFileSync(appcast, "utf8");
    if (!xml.includes(`Microgravity-${info.version}.zip`) || !xml.includes(`sparkle:version="${info.buildNumber}"`)) throw new Error("published appcast identity mismatch");
    const signature = xml.match(/<enclosure\b[^>]*sparkle:edSignature="([^"]+)"/)?.[1];
    if (!signature) throw new Error("published appcast has no Sparkle archive signature");
    verifySparkleFeed(appcast);
    verifySparkleArchive(zip, signature);
    await verifyLiveFeed(info, temp);
    console.log(`release:verify:published: ok (${info.tag})`);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    const action = process.argv[2];
    if (action === "prepare") prepare();
    else if (action === "continue") continueRelease();
    else if (action === "publish") publish();
    else if (action === "verify-published") await verifyPublished();
    else throw new Error("Usage: release.mjs prepare|continue|publish|verify-published");
  } catch (error) {
    console.error(`release: FAILED:\n${error.message}`);
    process.exit(1);
  }
}
