// The update check, checked here: which release is offered, and which is not.
//
//   node --test windows/update-check.test.mjs

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const { isNewer, pickRelease } = require("./electron/update-check.js");

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
  // The note is a question when it is clicked.
  assert.match(main, /note\.on\('click', \(\) => \{ void checkForUpdates\(\); \}\)/);
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
