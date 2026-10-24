#!/usr/bin/env node
// The capture matrix: the page in every state the Mac's screenshots cover, in both themes.
//
//   node windows/harness/captures.mjs [base] [folder]
//
// The base is the harness (http://127.0.0.1:4620/ by default); the folder is where the
// pictures are written. Every capture is checked for the page's own errors: a state that
// throws is a defect, whatever it looks like.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const base = process.argv[2] ?? "http://127.0.0.1:4620/";
const folder = process.argv[3] ?? path.join(here, "..", "..", "docs", "captures");
const executablePath = process.env.KUVO_CHROME || undefined;

fs.mkdirSync(folder, { recursive: true });
const browser = await chromium.launch({
  executablePath,
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--font-render-hinting=none"],
});

const problems = [];

async function shot(name, theme, width, height, act) {
  const page = await browser.newPage({ viewport: { width, height }, colorScheme: theme, deviceScaleFactor: 2 });
  page.on("pageerror", error => problems.push(`${name}: ${error}`));
  page.on("console", message => { if (message.type() === "error") problems.push(`${name}: ${message.text()}`); });
  await page.addInitScript(t => {
    localStorage.setItem("kuvo-analytics-ack", "1");
    localStorage.setItem("kuvo-look", JSON.stringify({ accent: "system", textSize: "14", motion: "full", theme: t }));
  }, theme);
  await page.goto(base, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2400);
  if (act) await act(page);
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(folder, `${name}.png`) });
  console.log("saved", `${name}.png`);
  await page.close();
}

const start = async page => {
  const button = page.locator("#start");
  if (await button.isVisible().catch(() => false)) {
    await button.click();
    await page.waitForTimeout(1500);
  }
};
const send = async page => {
  const prompt = page.locator("#prompt");
  if (await prompt.isVisible().catch(() => false)) {
    await prompt.fill("Say hello in one short sentence.");
    await prompt.press("Enter");
    await page.waitForTimeout(1800);
  }
};
const palette = async page => { await page.keyboard.press("Control+k"); await page.waitForTimeout(500); };
const settings = async page => {
  const button = page.locator("#settings-open");
  if (await button.isVisible().catch(() => false)) {
    await button.click();
    await page.waitForTimeout(600);
  }
};
const panel = async page => {
  const button = page.locator("#toggle-files");
  if (await button.isVisible().catch(() => false)) {
    await button.click();
    await page.waitForTimeout(600);
  }
};
const find = async page => {
  await page.keyboard.press("Control+f");
  await page.waitForTimeout(500);
};

await shot("01-empty-light", "light", 1440, 900);
await shot("02-session-light", "light", 1440, 900, start);
await shot("03-palette-light", "light", 1440, 900, async page => { await start(page); await palette(page); });
await shot("04-appearance-light", "light", 1440, 900, settings);
await shot("05-panel-light", "light", 1440, 900, async page => { await start(page); await panel(page); });
await shot("06-find-light", "light", 1440, 900, find);
await shot("07-reply-light", "light", 1440, 900, async page => { await start(page); await send(page); });
await shot("08-empty-dark", "dark", 1440, 900);
await shot("09-session-dark", "dark", 1440, 900, start);
await shot("10-appearance-dark", "dark", 1440, 900, settings);
await shot("11-narrow", "light", 1000, 700);

await browser.close();

if (problems.length) {
  console.error("the page complained:");
  for (const problem of problems) console.error(`  ${problem}`);
  process.exit(1);
}
console.log(`ok: ${folder} holds the matrix, and the page had nothing to complain about`);
