import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { githubOutput, githubRun } from "../lib/github.mjs";
import { run } from "../lib/core.mjs";

function makeFakeGitHub(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mg-fake-gh-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const executable = path.join(directory, "gh");
  fs.writeFileSync(executable, "#!/bin/sh\nprintf 'GH_TOKEN=%s\\nGITHUB_TOKEN=%s\\n' \"${GH_TOKEN:+present}\" \"${GITHUB_TOKEN:+present}\"\n");
  fs.chmodSync(executable, 0o755);
  return directory;
}

test("GitHub command wrappers pass either supported token while generic commands strip both", (t) => {
  const original = {
    GH_TOKEN: process.env.GH_TOKEN,
    GITHUB_TOKEN: process.env.GITHUB_TOKEN,
    PATH: process.env.PATH,
  };
  t.after(() => {
    for (const key of ["GH_TOKEN", "GITHUB_TOKEN", "PATH"]) {
      if (original[key] === undefined) delete process.env[key];
      else process.env[key] = original[key];
    }
  });

  const fakePath = makeFakeGitHub(t);
  process.env.PATH = `${fakePath}:${original.PATH ?? ""}`;
  for (const tokenName of ["GH_TOKEN", "GITHUB_TOKEN"]) {
    delete process.env.GH_TOKEN;
    delete process.env.GITHUB_TOKEN;
    process.env[tokenName] = "fake-token-never-print-this";

    const result = githubRun(["probe"], { capture: true });
    const expected = tokenName === "GH_TOKEN"
      ? "GH_TOKEN=present\nGITHUB_TOKEN="
      : "GH_TOKEN=\nGITHUB_TOKEN=present";
    assert.equal(String(result.stdout).trim(), expected);
    assert.equal(githubOutput(["probe"]).trim(), expected);
    assert.equal(String(run("gh", ["probe"], { capture: true }).stdout).trim(), "GH_TOKEN=\nGITHUB_TOKEN=");
  }
});
