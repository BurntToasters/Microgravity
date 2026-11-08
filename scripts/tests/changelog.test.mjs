import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { changelogSection, gpgFingerprint, placeholderReleaseNotes, releaseHeader, releaseNotes, releaseNotesFailures } from "../lib/changelog.mjs";
import { root } from "../lib/core.mjs";

// The 0.1.0 section is the first public release; it must carry real notes, not the placeholder.
const minimumReleaseItems = 8;

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

test("releaseNotes puts the download header above the section and ends with tagged source attribution", () => {
  const notes = releaseNotes({ version: "2.0.0", tag: "v2.0.0", channel: "stable" }, contents);
  assert.ok(notes.startsWith(releaseHeader({ version: "2.0.0", tag: "v2.0.0", channel: "stable" })));
  assert.ok(notes.endsWith("## Changes in `v2.0.0:`\n\n- Newest change.\n\nSource: v2.0.0 at 2.0.0. See the tagged repository for the complete corresponding source and bundled notices.\n"));
  assert.doesNotMatch(notes, /Beta build/);
});

test("releaseHeader links only this tag's release assets", () => {
  const header = releaseHeader({ version: "2.1.0-beta.1", tag: "v2.1.0-beta.1", channel: "beta" });
  assert.match(header, /^> \[!NOTE\]\n> 🅱️ This is a Beta build\./);
  const links = [...header.matchAll(/\]\((https:\/\/github\.com\/[^)]+)\)/g)].map((match) => match[1]);
  assert.deepEqual(links, [
    "https://github.com/BurntToasters/Microgravity/releases/download/v2.1.0-beta.1/Microgravity-2.1.0-beta.1.zip",
    "https://github.com/BurntToasters/Microgravity/releases/download/v2.1.0-beta.1/SHA256SUMS",
    "https://github.com/BurntToasters/Microgravity/releases/download/v2.1.0-beta.1/SHA256SUMS.asc",
  ]);
  assert.match(header, new RegExp(gpgFingerprint));
});

test("changelogSection fails when the requested release is missing", () => {
  assert.throws(() => changelogSection("3.0.0", contents), /CHANGELOG\.md has no 3\.0\.0 release section/);
});

test("the checked-in 0.1.0 release notes are publishable", () => {
  const changelog = fs.readFileSync(path.join(root, "CHANGELOG.md"), "utf8");
  assert.deepEqual(releaseNotesFailures("0.1.0", changelog, { minimumItems: minimumReleaseItems }), []);
});

test("releaseNotesFailures rejects placeholder and thin release sections", () => {
  for (const placeholder of placeholderReleaseNotes) {
    const failures = releaseNotesFailures("2.0.0", `# Microgravity changelog\n\n## 2.0.0\n\n- ${placeholder}\n`, { minimumItems: 1 });
    assert.equal(failures.length, 1);
    assert.match(failures[0], /still contains placeholder text/);
  }
  assert.deepEqual(releaseNotesFailures("2.0.0", contents, { minimumItems: 1 }), []);
  assert.match(releaseNotesFailures("2.0.0", contents, { minimumItems: 2 })[0], /has 1 bullet item\(s\); at least 2 are required/);
  assert.match(releaseNotesFailures("3.0.0", contents)[0], /CHANGELOG\.md has no 3\.0\.0 release section/);
});
