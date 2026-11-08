import fs from "node:fs";
import path from "node:path";
import { repositoryUrl, xmlEscape } from "./core.mjs";

export function appcastFilename(channel) {
  return channel === "beta" ? "appcast-beta.xml" : "appcast.xml";
}

export function renderAppcast(info, { signature, length, notes, publishedAt = new Date() }, baseUrl = repositoryUrl) {
  const file = `Microgravity-${info.version}.zip`;
  const downloadUrl = `${baseUrl}/releases/download/${info.tag}/${file}`;
  // Sparkle renders the embedded Markdown natively. A releaseNotesLink would make it load the whole
  // GitHub release page in its web view instead, so the appcast carries only the notes.
  if (!String(notes ?? "").trim()) throw new Error("Release notes are required for the appcast.");
  const releaseNotes = String(notes).trim().replaceAll("]]>", "]]]]><![CDATA[>");
  return `<?xml version="1.0" encoding="utf-8"?>\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n\t<channel>\n\t\t<title>Microgravity</title>\n\t\t<link>${xmlEscape(baseUrl)}</link>\n\t\t<description>Microgravity releases</description>\n\t\t<language>en</language>\n\t\t<item>\n\t\t\t<title>Microgravity ${xmlEscape(info.version)}</title>\n\t\t\t<pubDate>${publishedAt.toUTCString()}</pubDate>\n\t\t\t<enclosure url="${xmlEscape(downloadUrl)}" length="${length}" type="application/octet-stream" sparkle:version="${info.buildNumber}" sparkle:shortVersionString="${xmlEscape(info.version)}" sparkle:edSignature="${xmlEscape(signature)}" />\n\t\t\t<description sparkle:format="markdown"><![CDATA[${releaseNotes}]]></description>\n\t\t</item>\n\t</channel>\n</rss>\n`;
}

export function writeAppcast(directory, data, baseUrl = repositoryUrl) {
  const destination = path.join(directory, appcastFilename(data.info.channel));
  fs.writeFileSync(destination, renderAppcast(data.info, data, baseUrl));
  return destination;
}

export function copyStableAppcastAsBetaFallback(stableAppcast) {
  if (path.basename(stableAppcast) !== appcastFilename("stable")) throw new Error("beta fallback must copy the stable appcast");
  const destination = path.join(path.dirname(stableAppcast), appcastFilename("beta"));
  fs.copyFileSync(stableAppcast, destination);
  return destination;
}
