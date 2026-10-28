// A capture of the running page, for looking at the interface instead of guessing.
//
//   cd windows/harness && node server.mjs --port 4620 &
//   node windows/tools/capture.mjs http://127.0.0.1:4620/ /tmp/kuvo.png [width] [height] [dark]
//
// It drives the page with Playwright (the copy the MCP server ships) and writes a PNG. Two
// things are worth knowing when it runs where the browser is missing its fonts or its
// sandbox: the app's own font stack is left alone, and only the capture borrows a face that
// exists on the machine.
import { chromium } from "/home/user/tools/playwright-mcp/node_modules/playwright-core/index.mjs";
import fs from "node:fs";

const url = process.argv[2] ?? "http://127.0.0.1:4620/";
const out = process.argv[3] ?? "/tmp/kuvo.png";
const width = Number(process.argv[4] ?? 1440);
const height = Number(process.argv[5] ?? 900);
const dark = (process.argv[6] ?? "light") === "dark";
// Where the browser is, when it is not the one the system would find.
const executablePath = process.env.KUVO_CHROME || undefined;

const browser = await chromium.launch({
  executablePath,
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--font-render-hinting=none"],
});
const page = await browser.newPage({ viewport: { width, height }, colorScheme: dark ? "dark" : "light", deviceScaleFactor: 2 });
const problems = [];
page.on("pageerror", error => problems.push(String(error)));
await page.goto(url, { waitUntil: "domcontentloaded" });
// A machine with no sans-serif shows no text at all: the capture borrows one, the app does not.
await page.addStyleTag({
  content: 'body, button, input, textarea, select { font-family: "Liberation Sans", sans-serif !important; }',
}).catch(() => {});
if (dark) await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
await page.waitForTimeout(Number(process.env.KUVO_SHOT_WAIT ?? 3000));
await page.screenshot({ path: out });
console.log("saved", out, problems.length ? `| page errors: ${JSON.stringify(problems.slice(0, 5))}` : "| no page errors");
await browser.close();
