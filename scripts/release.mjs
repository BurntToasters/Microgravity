import fs from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { appcastFilename, copyStableAppcastAsBetaFallback, writeAppcast } from "./lib/appcast.mjs";
import { changelogSection, releaseNotes as formatReleaseNotes } from "./lib/changelog.mjs";
import { output, repository, repositoryUrl, root, run, sha256File, versionInfo } from "./lib/core.mjs";
import { githubOutput, githubRun } from "./lib/github.mjs";
import { buildRelease } from "./build.mjs";
import { draftTargetProblem, runPreflight, sparkleCredentialSources } from "./release-preflight.mjs";
import { artifactManifestPath, createArtifactManifest, createSession, validateArtifactManifest, verifySession } from "./release-session.mjs";

function ghResult(args) {
  return githubRun(args, { capture: true, allowFailure: true });
}

function ghRun(args) {
  return githubRun(args);
}

function ghOutput(args) {
  return githubOutput(args);
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
  return channel === "stable" ? [appcastFilename("stable"), appcastFilename("beta")] : [appcastFilename("beta")];
}

export function releaseAssetPlan(info) {
  const archiveName = `Microgravity-${info.version}.zip`;
  const canonicalFeedName = appcastFilename(info.channel);
  const feedNames = feedFilenames(info.channel);
  const checksummedNames = [archiveName, canonicalFeedName];
  const contentNames = [archiveName, ...feedNames, "SHA256SUMS"];
  return {
    archiveName,
    canonicalFeedName,
    feedNames,
    checksummedNames,
    contentNames,
    assetNames: [...contentNames, ...contentNames.map((name) => `${name}.asc`)],
    mutableFeedNames: info.channel === "stable" ? [appcastFilename("beta")] : [],
  };
}

// Returns true when the release is already published (rebuild and upload must be skipped).
function ensureDraft(info, commit) {
  const result = ghResult(["release", "view", info.tag, "--repo", repository, "--json", "isDraft,targetCommitish"]);
  if (result.status === 0) {
    const release = JSON.parse(result.stdout);
    if (!release.isDraft) return true;
    const problem = draftTargetProblem(release.targetCommitish, commit, info.tag);
    if (problem) throw new Error(problem);
    return false;
  }
  const draft = expectedDraftTarget(info, commit);
  const args = ["release", "create", draft.tag, "--repo", repository, "--draft", "--target", draft.target, "--title", draft.title, "--notes", `Microgravity ${info.version} release. See the tagged source and bundled notices for the corresponding GPL source and licensing information.`];
  if (draft.prerelease) args.push("--prerelease");
  ghRun(args);
  return false;
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

export function prepareReleaseAssets({
  info,
  zip,
  directory = path.dirname(zip),
  notes,
  signArchiveFile = (file) => signSparkle(file, true),
  verifySparkleArchiveFile = verifySparkleArchive,
  signFeedFile = (file) => signSparkle(file),
  signGpgFile = signGpg,
  verifyGpgFile = verifyGpg,
  verifySparkleFeedFile = verifySparkleFeed,
} = {}) {
  if (!info || !zip || !notes) throw new Error("release asset preparation requires release info, archive, and notes");
  fs.mkdirSync(directory, { recursive: true });
  const plan = releaseAssetPlan(info);
  const signature = signArchiveFile(zip);
  verifySparkleArchiveFile(zip, signature);
  const canonicalFeed = writeAppcast(directory, { info, signature, length: fs.statSync(zip).size, notes });
  signFeedFile(canonicalFeed);
  const feedPaths = [canonicalFeed];
  if (info.channel === "stable") feedPaths.push(copyStableAppcastAsBetaFallback(canonicalFeed));
  const checksumPaths = plan.checksummedNames.map((name) => path.join(directory, name));
  const checksums = writeChecksums(checksumPaths, path.join(directory, "SHA256SUMS"));
  const contentPaths = plan.contentNames.map((name) => path.join(directory, name));
  const assets = [...contentPaths, ...contentPaths.map((file) => signGpgFile(file))];
  for (const file of contentPaths) verifyGpgFile(file);
  for (const file of feedPaths) verifySparkleFeedFile(file);
  verifyChecksums(checksumPaths, checksums);
  return { plan, signature, canonicalFeed, feedPaths, checksums, contentPaths, assets };
}

function appcastIdentity(xml, info, feedName, { allowDifferentBuild = false } = {}) {
  const enclosure = xml.match(/<enclosure\b[^>]*>/)?.[0];
  const signature = enclosure?.match(/\bsparkle:edSignature="([^"]+)"/)?.[1];
  const feedBuild = enclosure?.match(/\bsparkle:version="([^"]+)"/)?.[1];
  const archiveName = enclosure?.match(/\burl="[^"]*\/(Microgravity-[^/?#"]+\.zip)(?:[?#][^"]*)?"/)?.[1];
  if (!enclosure || !signature || !feedBuild || !archiveName) throw new Error(`${feedName} is malformed or has no signed enclosure`);
  if (!allowDifferentBuild && (archiveName !== `Microgravity-${info.version}.zip` || feedBuild !== String(info.buildNumber)))
    throw new Error(`${feedName} does not describe ${info.tag}`);
  return { signature, feedBuild, archiveName };
}

export function verifyReleaseAssets(info, directory, {
  verifyGpgFile = verifyGpg,
  verifySparkleFeedFile = verifySparkleFeed,
  verifySparkleArchiveFile = verifySparkleArchive,
  allowMutableBetaFeed = false,
  requireExactAssets = false,
} = {}) {
  const plan = releaseAssetPlan(info);
  for (const name of plan.assetNames) {
    if (!fs.existsSync(path.join(directory, name))) throw new Error(`missing release asset: ${name}`);
  }
  if (requireExactAssets) {
    const actual = fs.readdirSync(directory).sort();
    if (JSON.stringify(actual) !== JSON.stringify([...plan.assetNames].sort())) throw new Error("release contains unexpected or missing assets");
  }
  const contentPaths = plan.contentNames.map((name) => path.join(directory, name));
  for (const file of contentPaths) verifyGpgFile(file);
  verifyChecksums(plan.checksummedNames.map((name) => path.join(directory, name)), path.join(directory, "SHA256SUMS"));

  for (const name of plan.feedNames) {
    const file = path.join(directory, name);
    const xml = fs.readFileSync(file, "utf8");
    const isMutableBetaMirror = info.channel === "stable" && name === appcastFilename("beta") && allowMutableBetaFeed;
    const identity = appcastIdentity(xml, info, name, { allowDifferentBuild: isMutableBetaMirror });
    verifySparkleFeedFile(file);
    if (name !== plan.canonicalFeedName && !isMutableBetaMirror && info.channel === "stable" && xml !== fs.readFileSync(path.join(directory, plan.canonicalFeedName), "utf8"))
      throw new Error("stable beta fallback does not match the stable appcast");
    if (!isMutableBetaMirror) verifySparkleArchiveFile(path.join(directory, plan.archiveName), identity.signature);
  }
  return plan;
}

export function verifyReleaseForPublication(info, session, manifest, directory, {
  alreadyPublished = false,
  verifyGpgFile = verifyGpg,
  verifySparkleFeedFile = verifySparkleFeed,
  verifySparkleArchiveFile = verifySparkleArchive,
} = {}) {
  const plan = releaseAssetPlan(info);
  const actual = fs.readdirSync(directory).sort();
  if (JSON.stringify(actual) !== JSON.stringify([...plan.assetNames].sort())) throw new Error("draft contains unexpected or missing assets");
  let releaseManifest = manifest;
  if (alreadyPublished && plan.mutableFeedNames.length) {
    if (!manifest || typeof manifest.assets !== "object" || manifest.assets === null) throw new Error("release artifact manifest does not match the session");
    const mirrorNames = new Set(plan.mutableFeedNames.flatMap((name) => [name, `${name}.asc`]));
    const assets = { ...manifest.assets };
    for (const name of mirrorNames) assets[name] = sha256File(path.join(directory, name));
    releaseManifest = { ...manifest, assets };
  }
  validateArtifactManifest(releaseManifest, session, directory, plan.assetNames);
  verifyReleaseAssets(info, directory, {
    allowMutableBetaFeed: alreadyPublished,
    requireExactAssets: true,
    verifyGpgFile,
    verifySparkleFeedFile,
    verifySparkleArchiveFile,
  });
  return plan;
}

// Order matters: the stable mirror upload runs before the beta leaves draft. If the upload fails, the beta is
// still a draft and `release:mac:resume` can retry it. Re-publishing an already-published release re-uploads
// the mirror (it is mutable) but does not touch the release's draft state.
export function publishPreparedRelease(info, directory, {
  runRelease = ghRun,
  latestStableTag = () => ghOutput(["release", "view", "--repo", repository, "--json", "tagName", "--jq", ".tagName"]),
  alreadyPublished = false,
} = {}) {
  const mirror = info.channel === "beta" ? betaMirrorTarget(info.channel, latestStableTag()) : null;
  const feed = mirror ? path.join(directory, appcastFilename("beta")) : null;
  const signature = feed ? `${feed}.asc` : null;
  if (mirror && (!fs.existsSync(feed) || !fs.existsSync(signature))) throw new Error("verified beta feed or its GPG signature is missing");
  if (mirror) {
    runRelease(["release", "upload", mirror, "--repo", repository, "--clobber", feed, signature]);
  }
  if (!alreadyPublished) {
    runRelease(["release", "edit", info.tag, "--repo", repository, "--draft=false", ...(info.channel === "beta" ? ["--prerelease"] : ["--latest"])]);
  }
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
  if (ensureDraft(info, session.identity.commit)) {
    console.log(`release:mac:continue: ${info.tag} already published; run release:publish to re-verify and refresh the beta mirror.`);
    return;
  }
  const { zip } = buildRelease();
  const changelog = fs.readFileSync(path.join(root, "CHANGELOG.md"), "utf8");
  // GitHub gets the download header and the changes; Sparkle's update window gets only the changes.
  const notes = formatReleaseNotes(info, changelog);
  const { assets, plan } = prepareReleaseAssets({ info, zip, notes: changelogSection(info.version, changelog) });
  const manifest = createArtifactManifest(session, assets);
  fs.writeFileSync(artifactManifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  validateArtifactManifest(manifest, session, path.dirname(zip), plan.assetNames);
  ghRun(["release", "upload", info.tag, "--repo", repository, "--clobber", ...assets]);
  const notesFile = path.join(path.dirname(zip), "RELEASE_NOTES.md");
  fs.writeFileSync(notesFile, `${notes}\n`);
  ghRun(["release", "edit", info.tag, "--repo", repository, "--notes-file", notesFile]);
  console.log(`release:mac:continue: draft uploaded (${assets.map((asset) => path.basename(asset)).join(", ")})`);
}

function publish() {
  const session = verifySession();
  const info = runPreflight({ release: true });
  const plan = releaseAssetPlan(info);
  const expected = plan.assetNames;
  const manifest = JSON.parse(fs.readFileSync(artifactManifestPath, "utf8"));
  validateArtifactManifest(manifest, session, path.join(root, "dist"), expected);
  const release = JSON.parse(ghOutput(["release", "view", info.tag, "--repo", repository, "--json", "isDraft,isPrerelease"]));
  if (release.isPrerelease !== (info.channel === "beta")) throw new Error(`${info.tag} prerelease flag does not match the ${info.channel} channel`);
  const alreadyPublished = !release.isDraft;
  const downloaded = fs.mkdtempSync(path.join(os.tmpdir(), "microgravity-draft-"));
  try {
    ghRun(["release", "download", info.tag, "--repo", repository, "--dir", downloaded]);
    verifyReleaseForPublication(info, session, manifest, downloaded, { alreadyPublished });
    publishPreparedRelease(info, downloaded, { alreadyPublished });
  } finally { fs.rmSync(downloaded, { recursive: true, force: true }); }
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
  const lines = fs.readFileSync(checksumFile, "utf8").trim().split("\n");
  const expected = new Map();
  for (const line of lines) {
    const match = line.match(/^([a-f0-9]{64})  (.+)$/i);
    if (!match || expected.has(match[2])) throw new Error("published checksum manifest is malformed");
    expected.set(match[2], match[1].toLowerCase());
  }
  const names = files.map((file) => path.basename(file)).sort();
  if (JSON.stringify([...expected.keys()].sort()) !== JSON.stringify(names)) throw new Error("published checksum manifest has unexpected assets");
  for (const file of files) {
    if (expected.get(path.basename(file)) !== sha256File(file).toLowerCase()) throw new Error(`published checksum mismatch: ${path.basename(file)}`);
  }
}

async function verifyLiveFeed(info, directory, feedName, { allowDifferentBuild = false, attempts = 6 } = {}) {
  const url = `${repositoryUrl}/releases/latest/download/${feedName}`;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const response = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(15_000) });
    if (response.ok) {
      const contents = await response.text();
      try { appcastIdentity(contents, info, feedName, { allowDifferentBuild }); } catch {
        if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, 10_000));
        continue;
      }
      if (allowDifferentBuild || contents.includes(`sparkle:version="${info.buildNumber}"`)) {
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
    verifyReleaseAssets(info, temp, { allowMutableBetaFeed: info.channel === "stable", requireExactAssets: true });
    for (const feedName of feedFilenames(info.channel)) {
      const mutableBetaFeed = info.channel === "stable" && feedName === appcastFilename("beta");
      await verifyLiveFeed(info, temp, feedName, { allowDifferentBuild: mutableBetaFeed });
    }
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
