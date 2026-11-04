import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { expectedBranch, output, repository, repositoryUrl, root, run, versionInfo } from "./lib/core.mjs";
import { releaseNotes } from "./lib/changelog.mjs";
import { validateWorkspace } from "./validate.mjs";

const escapedRepository = repository.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const canonicalOrigin = new RegExp(`^(?:https://github\\.com/|git@github\\.com:)${escapedRepository}(?:\\.git)?/?$`, "i");

export function isCanonicalOrigin(origin) {
  return canonicalOrigin.test(origin ?? "");
}

export function validateRepositoryState({ version, branch, origin, status, head, remoteHead, upstream, tagHead = null, draftTarget = null }) {
  const failures = [];
  const requiredBranch = expectedBranch(version);
  if (!isCanonicalOrigin(origin)) failures.push(`origin must be ${repositoryUrl}`);
  if (branch !== requiredBranch) failures.push(`${version} releases must run from ${requiredBranch}`);
  if (status) failures.push("release worktree must be clean");
  if (upstream !== `origin/${branch}`) failures.push(`branch must track origin/${branch}`);
  if (head !== remoteHead) failures.push("HEAD is not pushed to its canonical origin branch");
  if (tagHead && tagHead !== head) failures.push(`existing v${version} tag targets another commit`);
  if (draftTarget && ![head, branch].includes(draftTarget)) failures.push(`existing v${version} draft targets another commit`);
  return failures;
}

export function buildNumberFailures(buildNumber, releasedBuilds) {
  return Object.entries(releasedBuilds).filter(([, build]) => build >= buildNumber)
    .map(([tag, build]) => `buildNumber ${buildNumber} must be higher than ${tag}'s ${build}, or Sparkle will not offer the update`);
}

export function sparkleCredentialSources(environment = process.env) {
  return ["MICROGRAVITY_SPARKLE_ACCOUNT", "MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE", "MICROGRAVITY_SPARKLE_PRIVATE_KEY"].filter((name) => environment[name]);
}

function optional(command, args) {
  const result = run(command, args, { capture: true, allowFailure: true });
  return result.status === 0 ? String(result.stdout).trim() : null;
}

function releasedBuildNumbers(currentTag) {
  const tags = optional("git", ["tag", "--list", "v*"])?.split(/\s+/).filter((tag) => tag && tag !== currentTag) ?? [];
  return Object.fromEntries(tags.map((tag) => {
    try {
      const packageJson = JSON.parse(optional("git", ["show", `${tag}:package.json`]) ?? "{}");
      return [tag, Number(packageJson.buildNumber)];
    } catch {
      return [tag, Number.NaN];
    }
  }).filter(([, build]) => Number.isSafeInteger(build)));
}

function checkReleaseCredentials(failures) {
  const required = ["MICROGRAVITY_SPARKLE_PUBLIC_KEY", "MICROGRAVITY_SIGNING_IDENTITY", "MICROGRAVITY_TEAM_ID", "MICROGRAVITY_NOTARY_PROFILE", "MICROGRAVITY_GPG_KEY"];
  for (const key of required) if (!process.env[key]) failures.push(`${key} is required for a signed release`);

  const publicKey = process.env.MICROGRAVITY_SPARKLE_PUBLIC_KEY ?? "";
  if (publicKey) {
    const decoded = /^[A-Za-z0-9+/]+={0,2}$/.test(publicKey) ? Buffer.from(publicKey, "base64") : Buffer.alloc(0);
    if (decoded.length !== 32 || decoded.toString("base64") !== publicKey) failures.push("MICROGRAVITY_SPARKLE_PUBLIC_KEY is not a valid Sparkle public key");
  }
  if (process.env.MICROGRAVITY_TEAM_ID && !/^[A-Z0-9]{10}$/.test(process.env.MICROGRAVITY_TEAM_ID)) failures.push("MICROGRAVITY_TEAM_ID must be a 10-character Apple Team ID");

  const privateKeyFile = process.env.MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE;
  if (privateKeyFile && !fs.existsSync(path.resolve(root, privateKeyFile))) failures.push("configured Sparkle private-key file does not exist");

  const sparkleSources = sparkleCredentialSources();
  if (sparkleSources.length !== 1) failures.push("configure exactly one Sparkle signing source: MICROGRAVITY_SPARKLE_ACCOUNT, MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE, or MICROGRAVITY_SPARKLE_PRIVATE_KEY");

  if (process.env.MICROGRAVITY_SIGNING_IDENTITY && process.env.MICROGRAVITY_TEAM_ID) {
    const identities = optional("security", ["find-identity", "-v", "-p", "codesigning"]) ?? "";
    if (!identities.includes(process.env.MICROGRAVITY_SIGNING_IDENTITY)) failures.push("configured Developer ID signing identity is not present in the keychain");
  }
  if (process.env.MICROGRAVITY_GPG_KEY) {
    const keys = optional("gpg", ["--batch", "--list-secret-keys", "--keyid-format", "LONG"]) ?? "";
    if (!keys.includes(process.env.MICROGRAVITY_GPG_KEY)) failures.push("configured GPG signing key is not available in the local key store");
  }
  const ghStatus = run("gh", ["auth", "status", "--hostname", "github.com"], { capture: true, allowFailure: true });
  if (ghStatus.status !== 0) failures.push("GitHub CLI authentication for github.com is required");
}

export function betaReleaseAllowed(version, stableTags) {
  return !version.includes("-beta.") || stableTags.some((tag) => !tag.includes("-beta."));
}

export function runPreflight({ release = false } = {}) {
  if (process.platform !== "darwin") throw new Error("Microgravity releases require macOS.");
  const failures = [];
  try { validateWorkspace({ release }); } catch (error) { failures.push(error.message); }

  const info = versionInfo();
  output("git", ["fetch", "origin", "--tags", "--prune"]);
  const branch = output("git", ["branch", "--show-current"]);
  const origin = output("git", ["remote", "get-url", "origin"]);
  const tagHead = optional("git", ["rev-list", "-n", "1", info.tag]);
  const draftTarget = optional("gh", ["api", `repos/${repository}/releases/tags/${info.tag}`, "--jq", ".target_commitish"]);
  const state = {
    version: info.version,
    branch,
    origin,
    status: output("git", ["status", "--porcelain"]),
    head: output("git", ["rev-parse", "HEAD"]),
    remoteHead: optional("git", ["rev-parse", `origin/${branch}`]),
    upstream: optional("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]),
    tagHead,
    draftTarget,
  };
  failures.push(...validateRepositoryState(state));
  failures.push(...buildNumberFailures(info.buildNumber, releasedBuildNumbers(info.tag)));

  const stableTags = optional("gh", ["release", "list", "--repo", repository, "--json", "tagName,isDraft", "--jq", ".[] | select(.isDraft == false) | .tagName"])?.split(/\s+/).filter(Boolean) ?? [];
  if (!betaReleaseAllowed(info.version, stableTags)) failures.push("beta publishing is blocked until a stable release is public");
  if (release) {
    checkReleaseCredentials(failures);
    try { releaseNotes(info, fs.readFileSync(path.join(root, "CHANGELOG.md"), "utf8")); } catch (error) { failures.push(error.message); }
  }
  if (failures.length) throw new Error(`release preflight failed:\n- ${failures.join("\n- ")}`);
  console.log(`release preflight: ok (${info.tag}, ${info.channel})`);
  return info;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    runPreflight({ release: process.argv.includes("--release") });
  } catch (error) {
    console.error(`release-preflight: FAILED:\n${error.message}`);
    process.exit(1);
  }
}
