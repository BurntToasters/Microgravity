import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { root } from "../lib/core.mjs";

test("test:all CLI handles help without starting quality gates", () => {
  const result = spawnSync(process.execPath, [path.join(root, "scripts/test-all.mjs"), "--help"], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /Usage: node scripts\/test-all\.mjs/);
});
