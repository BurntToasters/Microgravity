import { fail } from "./core.mjs";

const changelogTitle = "# Microgravity changelog\n\n";

export function changelogSection(version, contents) {
  const start = contents.search(new RegExp(`^## ${version.replaceAll(".", "\\.")}(?:\\s|$)`, "m"));
  if (start < 0) fail(`CHANGELOG.md has no ${version} release section.`);
  const next = contents.slice(start).search(/^## \S/m);
  return contents.slice(start, next < 0 ? undefined : start + next).trim();
}

export function releaseNotes(info, contents) {
  const section = changelogSection(info.version, contents);
  return `${section}\n\nSource: ${info.tag} at ${info.version}. See the tagged repository for the complete corresponding source and bundled notices.\n`;
}

export function expectedChangelog(current, version) {
  if (new RegExp(`^## ${version.replaceAll(".", "\\.")}(?:\\s|$)`, "m").test(current)) return current;
  if (!current.startsWith(changelogTitle)) fail(`CHANGELOG.md must start with "${changelogTitle.trim()}".`);
  return `${changelogTitle}## ${version}\n\nRelease notes pending.\n\n${current.slice(changelogTitle.length)}`;
}
