import assert from "node:assert/strict";
import test from "node:test";
import { changelogSection, releaseNotes } from "../lib/changelog.mjs";

const contents = `# Microgravity changelog

## 2.0.0

- Newest change.

## 1.5.0 - Maintenance

- Middle change.
- Another middle change.

## 1.0.0

- Initial change.`;

test("changelogSection returns the requested release up to the next heading", () => {
  assert.equal(changelogSection("2.0.0", contents), "## 2.0.0\n\n- Newest change.");
  assert.equal(changelogSection("1.5.0", contents), "## 1.5.0 - Maintenance\n\n- Middle change.\n- Another middle change.");
});

test("changelogSection returns the final release through end of file", () => {
  assert.equal(changelogSection("1.0.0", contents), "## 1.0.0\n\n- Initial change.");
});

test("releaseNotes includes the section and tagged source attribution", () => {
  assert.equal(
    releaseNotes({ version: "2.0.0", tag: "v2.0.0" }, contents),
    "## 2.0.0\n\n- Newest change.\n\nSource: v2.0.0 at 2.0.0. See the tagged repository for the complete corresponding source and bundled notices.\n",
  );
});

test("changelogSection fails when the requested release is missing", () => {
  assert.throws(() => changelogSection("3.0.0", contents), /CHANGELOG\.md has no 3\.0\.0 release section/);
});
