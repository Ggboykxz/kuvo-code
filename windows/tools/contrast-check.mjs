#!/usr/bin/env node
// Static contrast check using corrected DESIGN.md token values

function oklchToRgb(l, c, h) {
  const hRad = h * Math.PI / 180;
  const a = c * Math.cos(hRad);
  const b_ = c * Math.sin(hRad);
  
  const l2 = l + 0.3963377774 * a + 0.2158037573 * b_;
  const m = l - 0.1055613458 * a - 0.0638541728 * b_;
  const s = l - 0.0894841775 * a - 1.2914855480 * b_;
  
  const l3 = l2 * l2 * l2;
  const m3 = m * m * m;
  const s3 = s * s * s;
  
  const r = +4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
  const g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
  const b = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;
  
  const toSrgb = x => x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1/2.4) - 0.055;
  
  return [
    Math.round(Math.max(0, Math.min(1, toSrgb(r))) * 255),
    Math.round(Math.max(0, Math.min(1, toSrgb(g))) * 255),
    Math.round(Math.max(0, Math.min(1, toSrgb(b))) * 255),
  ];
}

function luminance(r, g, b) {
  const toLinear = x => x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
  return 0.2126 * toLinear(r / 255) + 0.7152 * toLinear(g / 255) + 0.0722 * toLinear(b / 255);
}

function contrastRatio(rgb1, rgb2) {
  const l1 = luminance(...rgb1);
  const l2 = luminance(...rgb2);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

// CORRECTED DESIGN.md tokens (light mode)
const tokens = {
  // Backgrounds
  "--bg": "oklch(99% 0.002 240)",
  "--panel": "oklch(100% 0 0)",
  "--panel-2": "oklch(96% 0.005 250)",
  "--code-bg": "oklch(94% 0.005 250)",
  
  // Foregrounds
  "--ink": "oklch(18% 0.012 250)",
  "--ink-soft": "oklch(54% 0.012 250)",
  "--ink-faint": "oklch(78% 0.012 250)",
  
  // Borders
  "--line": "oklch(92% 0.005 250)",
  "--line-soft": "oklch(94% 0.005 250)",
  
  // Accent (corrected)
  "--accent": "oklch(56% 0.18 255)",
  "--accent-soft": "rgba(47, 111, 235, 0.12)",
  
  // Semantic (corrected)
  "--success": "oklch(54% 0.18 140)",
  "--success-soft": "rgba(23, 163, 74, 0.12)",
  "--warn": "oklch(56% 0.18 85)",
  "--warn-soft": "rgba(234, 179, 8, 0.12)",
  "--danger": "oklch(55% 0.22 25)",
  "--danger-soft": "rgba(220, 38, 38, 0.12)",
};

function parseOklch(str) {
  const match = str.match(/oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+)\)/);
  if (!match) return null;
  return {
    l: parseFloat(match[1]) / 100,
    c: parseFloat(match[2]),
    h: parseFloat(match[3]),
  };
}

function parseRgba(str) {
  const match = str.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)/);
  if (!match) return null;
  return {
    r: parseFloat(match[1]),
    g: parseFloat(match[2]),
    b: parseFloat(match[3]),
    a: match[4] ? parseFloat(match[4]) : 1,
  };
}

function resolveColor(token) {
  if (token.startsWith("oklch")) {
    const parsed = parseOklch(token);
    if (!parsed) return null;
    return oklchToRgb(parsed.l, parsed.c, parsed.h);
  }
  if (token.startsWith("rgba")) {
    const parsed = parseRgba(token);
    if (!parsed) return null;
    const bg = [255, 255, 255];
    return [
      Math.round(parsed.r * parsed.a + bg[0] * (1 - parsed.a)),
      Math.round(parsed.g * parsed.a + bg[1] * (1 - parsed.a)),
      Math.round(parsed.b * parsed.a + bg[2] * (1 - parsed.a)),
    ];
  }
  return null;
}

console.log("=== Static Contrast Audit (CORRECTED tokens) ===\n");

const colors = {};
for (const [name, value] of Object.entries(tokens)) {
  const rgb = resolveColor(value);
  if (rgb) colors[name] = rgb;
}

const bgColors = ["--bg", "--panel", "--panel-2", "--code-bg"];
const fgColors = ["--ink", "--ink-soft", "--ink-faint", "--accent", "--success", "--warn", "--danger", "--line", "--line-soft"];

console.log("Color values (sRGB):");
for (const [name, rgb] of Object.entries(colors)) {
  console.log(`  ${name}: rgb(${rgb.join(", ")})`);
}

console.log("\n=== Contrast Ratios (WCAG 2.1 AA requires 4.5:1 for text, 3:1 for large text) ===\n");

let failed = 0;
let passed = 0;

for (const bg of bgColors) {
  if (!colors[bg]) continue;
  for (const fg of fgColors) {
    if (!colors[fg]) continue;
    const ratio = contrastRatio(colors[fg], colors[bg]);
    const aa = ratio >= 4.5 ? "✅" : "❌";
    const aaLarge = ratio >= 3 ? "✅" : "❌";
    if (ratio < 4.5) failed++;
    else passed++;
    console.log(`  ${fg} on ${bg}: ${ratio.toFixed(2)}:1  [AA: ${aa}  AA Large: ${aaLarge}]`);
  }
}

console.log(`\n=== Summary ===`);
console.log(`Passed (>= 4.5:1): ${passed}`);
console.log(`Failed (< 4.5:1): ${failed}`);

if (failed > 0) {
  console.log("\n❌ Some color combinations fail WCAG 2.1 AA contrast requirements.");
  process.exit(1);
} else {
  console.log("\n✅ All color combinations meet WCAG 2.1 AA contrast requirements.");
  process.exit(0);
}
