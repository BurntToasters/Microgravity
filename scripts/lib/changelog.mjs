import { fail } from "./core.mjs";

const changelogTitle = "# Microgravity changelog\n\n";

export function changelogSection(version, contents) {
  const heading = new RegExp(`^## ${version.replaceAll(".", "\\.")}(?:\\s|$)`, "m");
  const match = heading.exec(contents);
  if (!match) fail(`CHANGELOG.md has no ${version} release section.`);
  const start = match.index;
  const next = contents.slice(start + match[0].length).search(/^## \S/m);
  const end = next < 0 ? undefined : start + match[0].length + next;
  return contents.slice(start, end).trim();
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
