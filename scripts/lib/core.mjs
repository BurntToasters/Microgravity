import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

const [nodeMajor, nodeMinor] = process.versions.node.split(".").map(Number);
if (nodeMajor < 22 || (nodeMajor === 22 && nodeMinor < 12)) {
  throw new Error("Microgravity scripts require Node.js 22.12 or newer.");
}

try {
  process.loadEnvFile(path.join(root, ".env"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

export const repository = "BurntToasters/Microgravity";
export const repositoryUrl = `https://github.com/${repository}`;
export const bundleIdentifier = "run.rosie.microgravity";

const sensitiveEnvironmentKeys = [
  "MICROGRAVITY_SPARKLE_ACCOUNT",
  "MICROGRAVITY_SPARKLE_PRIVATE_KEY_FILE",
  "MICROGRAVITY_SPARKLE_PRIVATE_KEY",
  "MICROGRAVITY_GPG_PASSPHRASE",
  "MICROGRAVITY_KEYCHAIN_PASSWORD",
  "SSH_USER_PWD",
  "GH_TOKEN",
  "GITHUB_TOKEN",
];

export function fail(message) {
  throw new Error(message);
}

export function childEnvironment(environment = process.env, overrides = {}, allowedSecrets = []) {
  const child = { ...environment, ...overrides };
  for (const key of sensitiveEnvironmentKeys) if (!allowedSecrets.includes(key)) delete child[key];
  return child;
}

export function run(command, args = [], options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    env: childEnvironment(process.env, options.env, options.allowSecrets),
    encoding: "utf8",
    input: options.input,
    stdio: options.capture ? [options.input === undefined ? "ignore" : "pipe", "pipe", "pipe"] : options.input === undefined ? "inherit" : ["pipe", "inherit", "inherit"],
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    fail(`${command} ${args.join(" ")} failed with status ${result.status}${detail ? `:\n${detail}` : ""}`);
  }
  return result;
}

export function output(command, args = [], options = {}) {
  const result = run(command, args, { ...options, capture: true });
  return String(result.stdout ?? "").trimEnd();
}

export function readPackage(base = root) {
  return JSON.parse(fs.readFileSync(path.join(base, "package.json"), "utf8"));
}

export function versionInfo(base = root) {
  const packageJson = readPackage(base);
  const version = String(packageJson.version ?? "");
  const buildNumber = packageJson.buildNumber;
  if (!/^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-beta\.(?:0|[1-9]\d*))?$/.test(version)) {
    fail(`Unsupported Microgravity version: ${version}`);
  }
  if (!Number.isSafeInteger(buildNumber) || buildNumber < 1) fail("package.json buildNumber must be a positive integer.");
  return { version, buildNumber, channel: version.includes("-beta.") ? "beta" : "stable", tag: `v${version}` };
}

export function expectedBranch(version) {
  if (/^\d+\.\d+\.\d+-beta\.\d+$/.test(version)) return "beta";
  if (/^\d+\.\d+\.\d+$/.test(version)) return "main";
  fail(`Unsupported release version '${version}'; Microgravity releases use stable or beta versions only.`);
}

export function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

export function sha256File(filePath) {
  return sha256(fs.readFileSync(filePath));
}

function walk(directory) {
  if (!fs.existsSync(directory)) return [];
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink()) return [directory];
  if (!stat.isDirectory()) return [directory];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if ([".build", ".swiftpm", ".DS_Store", "DerivedData", "node_modules"].includes(entry.name)) return [];
    const absolute = path.join(directory, entry.name);
    return entry.isDirectory() ? walk(absolute) : [absolute];
  });
}

export function treeHash(paths, base = root) {
  const hash = crypto.createHash("sha256");
  for (const file of paths.flatMap((entry) => walk(path.resolve(base, entry))).sort()) {
    hash.update(path.relative(base, file));
    hash.update("\0");
    const stat = fs.lstatSync(file);
    hash.update(`mode:${stat.mode & 0o777}\0`);
    hash.update(stat.isSymbolicLink() ? `symlink:${fs.readlinkSync(file)}` : fs.readFileSync(file));
    hash.update("\0");
  }
  return hash.digest("hex");
}

export function xmlEscape(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

export function ensureDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true });
}

export function writeIfChanged(filePath, contents) {
  const current = fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : null;
  if (current === contents) return false;
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents);
  return true;
}
