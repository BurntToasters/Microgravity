import { output, run } from "./core.mjs";

const githubSecrets = ["GH_TOKEN", "GITHUB_TOKEN"];

export function githubRun(args = [], options = {}) {
  return run("gh", args, { ...options, allowSecrets: githubSecrets });
}

export function githubOutput(args = [], options = {}) {
  return output("gh", args, { ...options, allowSecrets: githubSecrets });
}
