import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { appcastFilename } from "../lib/appcast.mjs";
import { sha256File } from "../lib/core.mjs";
import { createArtifactManifest, validateArtifactManifest } from "../release-session.mjs";
import { repositoryUrl } from "../lib/core.mjs";
import { draftTargetProblem, validateRepositoryState } from "../release-preflight.mjs";
import {
  prepareReleaseAssets,
  releaseAssetPlan,
  publishPreparedRelease,
  verifyReleaseAssets,
  verifyReleaseForPublication,
} from "../release.mjs";

function mockSigning() {
  const calls = { archive: [], feed: [], gpg: [], verifiedGpg: [] };
  return {
    calls,
    signArchiveFile(file) {
      calls.archive.push(path.basename(file));
      return `sparkle:${sha256File(file)}`;
    },
    verifySparkleArchiveFile(file, signature) {
      assert.equal(signature, `sparkle:${sha256File(file)}`, `Sparkle archive signature must match ${path.basename(file)}`);
    },
    signFeedFile(file) {
      calls.feed.push(path.basename(file));
    },
    signGpgFile(file) {
      calls.gpg.push(path.basename(file));
      const signature = `${file}.asc`;
      fs.writeFileSync(signature, `mock-gpg:${sha256File(file)}\n`);
      return signature;
    },
    verifyGpgFile(file) {
      const signature = `${file}.asc`;
      if (!fs.existsSync(signature) || fs.readFileSync(signature, "utf8") !== `mock-gpg:${sha256File(file)}\n`)
        throw new Error(`mock GPG signature mismatch for ${path.basename(file)}`);
      calls.verifiedGpg.push(path.basename(file));
    },
    verifySparkleFeedFile(file) {
      const xml = fs.readFileSync(file, "utf8");
      if (!/<enclosure\b[^>]*sparkle:edSignature="[^"]+"/.test(xml)) throw new Error(`mock Sparkle feed signature missing: ${path.basename(file)}`);
    },
  };
}

function prepareFixture(t, info, signing = mockSigning()) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "microgravity-feed-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const zip = path.join(directory, `Microgravity-${info.version}.zip`);
  fs.writeFileSync(zip, `mock archive for ${info.tag}\n`);
  const prepared = prepareReleaseAssets({
    info,
    zip,
    notes: `Notes for ${info.tag}`,
    ...signing,
  });
  const session = { createdAt: "2026-11-05T00:00:00.000Z", identity: { commit: info.tag } };
  const manifest = createArtifactManifest(session, prepared.assets);
  validateArtifactManifest(manifest, session, directory, prepared.plan.assetNames);
  assert.doesNotThrow(() => verifyReleaseAssets(info, directory, { ...signing, requireExactAssets: true }));
  return { directory, zip, prepared, session, manifest, signing };
}

function materializeRelease(t, assets) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "microgravity-published-feed-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const [name, contents] of assets) fs.writeFileSync(path.join(directory, name), contents);
  return directory;
}

function mockGithub() {
  const releases = new Map();
  const uploads = [];
  let latestStableTag = null;
  return {
    releases,
    uploads,
    attachDraft(info, prepared) {
      releases.set(info.tag, {
        draft: true,
        prerelease: info.channel === "beta",
        assets: new Map(prepared.assets.map((file) => [path.basename(file), fs.readFileSync(file)])),
      });
    },
    runRelease(args) {
      if (args[1] === "edit") {
        const release = releases.get(args[2]);
        assert.ok(release, `mock release exists: ${args[2]}`);
        if (args.includes("--draft=false")) release.draft = false;
        if (args.includes("--latest")) latestStableTag = args[2];
        return;
      }
      if (args[1] === "upload") {
        const tag = args[2];
        const release = releases.get(tag);
        assert.ok(release, `mock upload target exists: ${tag}`);
        const start = args.indexOf("--clobber") + 1;
        const files = args.slice(start);
        assert.ok(files.length > 0, "mock release upload includes assets");
        for (const file of files) release.assets.set(path.basename(file), fs.readFileSync(file));
        uploads.push({ tag, names: files.map((file) => path.basename(file)) });
        return;
      }
      throw new Error(`unexpected mocked GitHub command: ${args.join(" ")}`);
    },
    latestStableTag: () => latestStableTag,
    latestDownload(name) {
      return latestStableTag ? releases.get(latestStableTag)?.assets.get(name) ?? null : null;
    },
  };
}

function assertLatestBetaFeed(github, info) {
  const feed = github.latestDownload("appcast-beta.xml");
  const signature = github.latestDownload("appcast-beta.xml.asc");
  assert.ok(feed, "/releases/latest/download/appcast-beta.xml is present");
  assert.ok(signature, "/releases/latest/download/appcast-beta.xml.asc is present");
  const xml = feed.toString("utf8");
  assert.match(xml, new RegExp(`sparkle:version="${info.buildNumber}"`));
  assert.ok(xml.includes(`/${info.tag}/Microgravity-${info.version}.zip`));
  const digest = crypto.createHash("sha256").update(feed).digest("hex");
  assert.equal(signature.toString("utf8"), `mock-gpg:${digest}\n`);
}

test("stable, beta, stable publication keeps the latest beta feed attached to the current stable build", (t) => {
  const github = mockGithub();
  const stable1 = { version: "0.9.0", buildNumber: 90, channel: "stable", tag: "v0.9.0" };
  const beta1 = { version: "0.10.0-beta.1", buildNumber: 101, channel: "beta", tag: "v0.10.0-beta.1" };
  const stable2 = { version: "0.10.0", buildNumber: 102, channel: "stable", tag: "v0.10.0" };
  const first = prepareFixture(t, stable1);
  const stablePlan = releaseAssetPlan(stable1);

  assert.deepEqual(stablePlan.feedNames, ["appcast.xml", "appcast-beta.xml"]);
  assert.deepEqual(stablePlan.checksummedNames, [`Microgravity-${stable1.version}.zip`, "appcast.xml"]);
  assert.deepEqual(Object.keys(first.manifest.assets).sort(), [...stablePlan.assetNames].sort());
  assert.ok(Object.hasOwn(first.manifest.assets, "appcast-beta.xml.asc"));
  assert.deepEqual(
    fs.readFileSync(path.join(first.directory, "SHA256SUMS"), "utf8").trim().split("\n").map((line) => line.split(/\s{2}/)[1]).sort(),
    [...stablePlan.checksummedNames].sort(),
  );
  assert.equal(fs.readFileSync(path.join(first.directory, "appcast.xml"), "utf8"), fs.readFileSync(path.join(first.directory, "appcast-beta.xml"), "utf8"));
  assert.ok(first.signing.calls.verifiedGpg.includes("appcast-beta.xml"));
  assert.ok(first.signing.calls.gpg.includes("appcast-beta.xml"));
  assert.equal(first.signing.calls.archive.length, 1);
  assert.deepEqual(first.signing.calls.feed, ["appcast.xml"]);
  github.attachDraft(stable1, first.prepared);
  publishPreparedRelease(stable1, first.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });
  assert.equal(github.latestStableTag(), stable1.tag);
  assertLatestBetaFeed(github, stable1);

  const beta = prepareFixture(t, beta1);
  const betaPlan = releaseAssetPlan(beta1);
  assert.deepEqual(betaPlan.checksummedNames, [`Microgravity-${beta1.version}.zip`, "appcast-beta.xml"]);
  assert.deepEqual(
    fs.readFileSync(path.join(beta.directory, "SHA256SUMS"), "utf8").trim().split("\n").map((line) => line.split(/\s{2}/)[1]).sort(),
    [...betaPlan.checksummedNames].sort(),
  );
  github.attachDraft(beta1, beta.prepared);
  publishPreparedRelease(beta1, beta.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });
  assert.equal(github.latestStableTag(), stable1.tag);
  assertLatestBetaFeed(github, beta1);
  assert.deepEqual(github.uploads.at(-1), { tag: stable1.tag, names: ["appcast-beta.xml", "appcast-beta.xml.asc"] });

  const stable1AfterBeta = materializeRelease(t, github.releases.get(stable1.tag).assets);
  assert.doesNotThrow(() => verifyReleaseAssets(stable1, stable1AfterBeta, { ...first.signing, allowMutableBetaFeed: true, requireExactAssets: true }));

  const second = prepareFixture(t, stable2);
  const secondPlan = releaseAssetPlan(stable2);
  assert.deepEqual(Object.keys(second.manifest.assets).sort(), [...secondPlan.assetNames].sort());
  github.attachDraft(stable2, second.prepared);
  publishPreparedRelease(stable2, second.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });
  assert.equal(github.latestStableTag(), stable2.tag);
  assertLatestBetaFeed(github, stable2);

  const beta2 = { version: "0.11.0-beta.1", buildNumber: 111, channel: "beta", tag: "v0.11.0-beta.1" };
  const betaAgain = prepareFixture(t, beta2);
  github.attachDraft(beta2, betaAgain.prepared);
  publishPreparedRelease(beta2, betaAgain.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });
  assertLatestBetaFeed(github, beta2);

  const stable2AfterBeta = materializeRelease(t, github.releases.get(stable2.tag).assets);
  assert.doesNotThrow(() => verifyReleaseForPublication(stable2, second.session, second.manifest, stable2AfterBeta, {
    alreadyPublished: true,
    ...second.signing,
  }));
  publishPreparedRelease(stable2, stable2AfterBeta, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });
  assert.equal(github.latestStableTag(), stable2.tag);
  assertLatestBetaFeed(github, beta2);
});

test("stable fallback feed is required, signed, and rejected when malformed", (t) => {
  const info = { version: "1.2.3", buildNumber: 123, channel: "stable", tag: "v1.2.3" };
  const fixture = prepareFixture(t, info);
  const fallback = path.join(fixture.directory, appcastFilename("beta"));

  fs.writeFileSync(`${fallback}.asc`, "tampered signature\n");
  assert.throws(() => verifyReleaseAssets(info, fixture.directory, fixture.signing), /GPG signature mismatch/);

  fixture.signing.signGpgFile(fallback);
  assert.equal(
    fs.readFileSync(`${fallback}.asc`, "utf8"),
    `mock-gpg:${sha256File(fallback)}\n`,
  );
  fs.rmSync(fallback);
  assert.throws(() => verifyReleaseAssets(info, fixture.directory, fixture.signing), /missing release asset: appcast-beta\.xml/);

  fs.writeFileSync(fallback, "<rss><channel><item></item></channel></rss>\n");
  fixture.signing.signGpgFile(fallback);
  assert.throws(() => verifyReleaseAssets(info, fixture.directory, fixture.signing), /appcast-beta\.xml is malformed/);
});

test("beta mirror upload runs before draft=false, so a failed upload leaves the beta resumable", (t) => {
  const github = mockGithub();
  const stable = { version: "0.9.0", buildNumber: 90, channel: "stable", tag: "v0.9.0" };
  const beta = { version: "0.10.0-beta.1", buildNumber: 101, channel: "beta", tag: "v0.10.0-beta.1" };
  const stableFixture = prepareFixture(t, stable);
  github.attachDraft(stable, stableFixture.prepared);
  publishPreparedRelease(stable, stableFixture.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });

  const betaFixture = prepareFixture(t, beta);
  github.attachDraft(beta, betaFixture.prepared);
  const attempted = [];
  const failingUpload = (args) => {
    attempted.push(`${args[1]} ${args[2]}${args.includes("--draft=false") ? " draft=false" : ""}`);
    if (args[1] === "upload") throw new Error("mirror upload failed");
    return github.runRelease(args);
  };
  assert.throws(() => publishPreparedRelease(beta, betaFixture.directory, { runRelease: failingUpload, latestStableTag: github.latestStableTag }), /mirror upload failed/);
  assert.equal(github.releases.get(beta.tag).draft, true, "beta stays a draft when the mirror upload fails");
  assert.ok(!attempted.some((call) => call.includes("draft=false")), "no draft=false call after a failed mirror upload");

  const calls = [];
  const recording = (args) => {
    calls.push(`${args[1]} ${args[2]}${args.includes("--draft=false") ? " draft=false" : ""}`);
    return github.runRelease(args);
  };
  publishPreparedRelease(beta, betaFixture.directory, { runRelease: recording, latestStableTag: github.latestStableTag });
  assert.deepEqual(calls, [`upload ${stable.tag}`, `edit ${beta.tag} draft=false`]);
  assert.equal(github.releases.get(beta.tag).draft, false);
  assertLatestBetaFeed(github, beta);
});

test("re-publishing an already-published beta refreshes the mirror without touching draft state", (t) => {
  const github = mockGithub();
  const stable = { version: "0.9.0", buildNumber: 90, channel: "stable", tag: "v0.9.0" };
  const beta = { version: "0.10.0-beta.1", buildNumber: 101, channel: "beta", tag: "v0.10.0-beta.1" };
  const stableFixture = prepareFixture(t, stable);
  github.attachDraft(stable, stableFixture.prepared);
  publishPreparedRelease(stable, stableFixture.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });
  const betaFixture = prepareFixture(t, beta);
  github.attachDraft(beta, betaFixture.prepared);
  publishPreparedRelease(beta, betaFixture.directory, { runRelease: github.runRelease, latestStableTag: github.latestStableTag });

  const calls = [];
  publishPreparedRelease(beta, betaFixture.directory, {
    runRelease: (args) => {
      calls.push(args[1]);
      return github.runRelease(args);
    },
    latestStableTag: github.latestStableTag,
    alreadyPublished: true,
  });
  assert.deepEqual(calls, ["upload"]);
  assert.equal(github.releases.get(beta.tag).draft, false);
  assertLatestBetaFeed(github, beta);
});

test("release drafts must target the verified commit SHA, never a branch name", () => {
  const sha = "a".repeat(40);
  const other = "b".repeat(40);
  assert.equal(draftTargetProblem(sha, sha, "v1.0.0"), null);
  assert.equal(draftTargetProblem(null, sha, "v1.0.0"), null);
  assert.match(draftTargetProblem("main", sha, "v1.0.0"), /draft targets branch main.*Delete the draft/);
  assert.match(draftTargetProblem("beta", sha, "v0.10.0-beta.1"), /draft targets branch beta/);
  assert.match(draftTargetProblem(other, sha, "v1.0.0"), /not this release commit/);

  const state = { version: "1.0.0", branch: "main", origin: `${repositoryUrl}.git`, status: "", head: sha, remoteHead: sha, upstream: "origin/main", tagHead: null };
  assert.deepEqual(validateRepositoryState({ ...state, draftTarget: null }), []);
  assert.deepEqual(validateRepositoryState({ ...state, draftTarget: sha }), []);
  assert.match(validateRepositoryState({ ...state, draftTarget: "main" }).join("\n"), /draft targets branch main/);
});
