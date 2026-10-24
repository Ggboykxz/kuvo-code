#!/usr/bin/env node
// Contrast audit using axe-core on the built page
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

const BUILD_DIR = path.join(process.cwd(), "windows", "harness", "ui-build");
const INDEX = path.join(BUILD_DIR, "index.html");

if (!fs.existsSync(INDEX)) {
  console.error("Build not found. Run `npm run build` in windows/app first.");
  process.exit(1);
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
await page.goto(`file://${path.resolve(INDEX)}`, { waitUntil: "networkidle" });

// Wait for the app to initialize
await page.waitForTimeout(1000);

// Run axe-core
const results = await new AxeBuilder({ page })
  .withTags(["wcag2aa", "wcag21aa"])
  .analyze();

console.log("=== Contrast Audit Results ===");
console.log(`URL: file://${path.resolve(INDEX)}`);
console.log(`Timestamp: ${new Date().toISOString()}`);
console.log("");

const violations = results.violations.filter(v => v.id === "color-contrast");
if (violations.length === 0) {
  console.log("✅ No color-contrast violations found (WCAG 2.1 AA)");
} else {
  console.log(`❌ Found ${violations.length} color-contrast violation(s):`);
  for (const v of violations) {
    console.log(`\n  Rule: ${v.id} (${v.impact})`);
    console.log(`  Description: ${v.description}`);
    console.log(`  Help: ${v.help}`);
    console.log(`  Nodes affected: ${v.nodes.length}`);
    for (const node of v.nodes.slice(0, 3)) {
      console.log(`    - ${node.target.join(" > ")}`);
      console.log(`      Contrast: ${node.any?.[0]?.relatedNodes?.[0]?.target?.[0] || "N/A"}`);
    }
    if (v.nodes.length > 3) console.log(`    ... and ${v.nodes.length - 3} more`);
  }
}

// Also check all violations
const allViolations = results.violations;
if (allViolations.length > 0) {
  console.log(`\n=== All Violations (${allViolations.length}) ===`);
  for (const v of allViolations) {
    console.log(`  ${v.id} (${v.impact}): ${v.nodes.length} node(s)`);
  }
}

const passes = results.passes.length;
console.log(`\n✅ Passed rules: ${passes}`);
console.log(`❌ Violations: ${allViolations.length}`);
console.log(`⚠️  Incomplete: ${results.incomplete.length}`);
console.log(`📊 Inapplicable: ${results.inapplicable.length}`);

await browser.close();

// Exit with error code if violations found
process.exit(violations.length > 0 ? 1 : 0);
