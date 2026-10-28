// The update check, checked here: which release is offered, and which is not.
//
//   node --test windows/update-check.test.mjs

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const { isNewer, pickRelease, parseAtom, describeError } = require("./electron/update-check.js");

const release = (version, assets = [`Kuvo-Code-Setup-${version}.exe`]) => ({
  tag_name: `windows-v${version}`,
  draft: false,
  published_at: "2026-10-19T19:00:00Z",
  body: "notes",
  assets: assets.map(name => ({ name, browser_download_url: `https://example.invalid/${name}` })),
});

test("a version is newer than another", () => {
  assert.ok(isNewer("0.5.34", "0.5.33"));
  assert.ok(isNewer("0.6.0", "0.5.33"));
  assert.ok(isNewer("1.0.0", "0.5.33"));
  assert.ok(!isNewer("0.5.33", "0.5.33"), "the same one is not newer");
  assert.ok(!isNewer("0.5.32", "0.5.33"));
  assert.ok(!isNewer("not a version", "0.5.33"));
});

test("the newest of ours, that is newer, is the one offered", () => {
  const update = pickRelease([release("0.5.31"), release("0.5.34"), release("0.5.33")], "0.5.32");
  assert.equal(update.version, "0.5.34");
  assert.equal(update.name, "Kuvo-Code-Setup-0.5.34.exe");
  assert.match(update.url, /Kuvo-Code-Setup-0\.5\.34\.exe$/);
});

test("the shell keeps looking, so a version published while it is open is found", () => {
  const main = require("node:fs").readFileSync(
    require("node:path").join(require("node:path").dirname(require("node:url").fileURLToPath(import.meta.url)), "electron", "main.js"),
    "utf8",
  );
  assert.match(main, /setInterval\(\(\) => \{/, "the check runs again and again");
  assert.match(main, /6 \* 60 \* 60 \* 1000/, "every few hours");
  assert.match(main, /checkForUpdates\(\{ quiet: true \}\)/, "and quietly, so it is a note and not a question");
  // The note is a question when it is clicked — about the version it already found, rather
  // than a second check that could answer something else by then.
  assert.match(main, /note\.on\('click', \(\) => \{ void askToInstall\(update\); \}\)/);
});

test("what is running, or older, is not offered", () => {
  assert.equal(pickRelease([release("0.5.33")], "0.5.33"), null);
  assert.equal(pickRelease([release("0.5.32")], "0.5.33"), null);
  assert.equal(pickRelease([], "0.5.33"), null);
});

test("another release — a draft, or another tag — is not ours", () => {
  assert.equal(pickRelease([{ ...release("9.9.9"), draft: true }], "0.5.33"), null);
  assert.equal(pickRelease([{ ...release("9.9.9"), tag_name: "v9.9.9" }], "0.5.33"), null);
});

test("a release without the installer is not offered", () => {
  assert.equal(pickRelease([release("0.5.34", ["kuvo-code-0.5.34-source.zip"])], "0.5.33"), null);
});

// The feed is the fallback when the API is limited or blocked. It lists the tag and the
// date, not the assets; the installer's name is ours, so the tag is enough to place it.
const FEED = `<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
  <title>Release notes from kuvo-code</title>
  <entry>
    <id>tag:github.com,2008:Repository/1424151930/windows-v0.7.2</id>
    <updated>2026-10-27T01:01:29Z</updated>
    <link rel="alternate" type="text/html" href="https://github.com/Ggboykxz/kuvo-code/releases/tag/windows-v0.7.2"/>
    <title>Kuvo Code 0.7.2</title>
  </entry>
  <entry>
    <id>tag:github.com,2008:Repository/1424151930/windows-v0.7.1</id>
    <updated>2026-10-26T12:00:00Z</updated>
    <title>Kuvo Code 0.7.1</title>
  </entry>
  <entry>
    <id>tag:github.com,2008:Repository/1424151930/v0.3.0</id>
    <updated>2025-01-01T00:00:00Z</updated>
    <title>Kuvo Code 0.3.0, the Mac's</title>
  </entry>
</feed>`;

test("the releases feed is read into the same shape, and the newest of ours wins", () => {
  const releases = parseAtom(FEED);
  assert.deepEqual(releases.map(entry => entry.tag_name), ["windows-v0.7.2", "windows-v0.7.1"]);
  const update = pickRelease(releases, "0.7.1");
  assert.equal(update.version, "0.7.2");
  assert.equal(update.name, "Kuvo-Code-Setup-0.7.2.exe");
  assert.equal(
    update.url,
    "https://github.com/Ggboykxz/kuvo-code/releases/download/windows-v0.7.2/Kuvo-Code-Setup-0.7.2.exe",
  );
  // A tag of the Mac's is not ours, and the feed is not newer than what is running.
  assert.equal(pickRelease(releases, "0.7.2"), null);
});

test("a feed with nothing of ours offers nothing", () => {
  assert.deepEqual(parseAtom("<feed></feed>"), []);
  assert.deepEqual(parseAtom(""), []);
  assert.equal(pickRelease(parseAtom(FEED.replace(/windows-v/g, "v")), "0.7.1"), null);
});

test("an error says what happened, in words about the network rather than the socket", () => {
  assert.match(describeError(new Error("GitHub answered 403")), /limiting requests/);
  assert.match(describeError(new Error("GitHub answered 404")), /could not be found/);
  assert.match(describeError(new Error("GitHub answered 502")), /GitHub had a problem/);
  assert.match(describeError(new Error("fetch failed")), /couldn't reach GitHub/);
  assert.match(describeError(new Error("UNABLE_TO_VERIFY_LEAF_SIGNATURE")), /couldn't reach GitHub/);
  // Anything else is its own words, not a guess.
  assert.equal(describeError(new Error("the download failed (500)")), "the download failed (500)");
  assert.equal(describeError(null), "Something went wrong.");
});
