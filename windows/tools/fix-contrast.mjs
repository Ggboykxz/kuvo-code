#!/usr/bin/env node
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

function oklchToRgbVal(l, c, h) {
  return oklchToRgb(l, c, h);
}

function requiredLightness(targetRatio) {
  const bg = [255, 255, 255];
  let low = 0, high = 1;
  for (let i = 0; i < 30; i++) {
    const mid = (low + high) / 2;
    const rgb = oklchToRgbVal(mid, 0, 0);
    const ratio = contrastRatio(rgb, bg);
    if (ratio >= targetRatio) high = mid;
    else low = mid;
  }
  return high;
}

function contrastRatio(rgb1, rgb2) {
  const l1 = luminance(...rgb1);
  const l2 = luminance(...rgb2);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

function luminance(r, g, b) {
  const toLinear = x => x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
  return 0.2126 * toLinear(r / 255) + 0.7152 * toLinear(g / 255) + 0.0722 * toLinear(b / 255);
}

const l_ink = requiredLightness(4.5);
const l_ink_soft = requiredLightness(4.5);
const l_accent = requiredLightness(4.5);
const l_warn = requiredLightness(4.5);
const l_success = requiredLightness(4.5);
const l_danger = requiredLightness(4.5);

console.log("Required lightness for 4.5:1 on white:");
console.log(`  ink: ${(l_ink*100).toFixed(1)}%`);
console.log(`  ink-soft: ${(l_ink_soft*100).toFixed(1)}%`);
console.log(`  accent: ${(l_accent*100).toFixed(1)}%`);
console.log(`  warn: ${(l_warn*100).toFixed(1)}%`);
console.log(`  success: ${(l_success*100).toFixed(1)}%`);
console.log(`  danger: ${(l_danger*100).toFixed(1)}%`);

console.log("\nCurrent vs Required:");
console.log("  ink: 18% -> " + (l_ink*100).toFixed(1) + "% ✓");
console.log("  ink-soft: 54% -> " + (l_ink_soft*100).toFixed(1) + "% (needs darker)");
console.log("  ink-faint: 78% -> ~40% (for 3:1 large text only)");
console.log("  accent: 58% -> " + (l_accent*100).toFixed(1) + "% (needs darker)");
console.log("  warn: 70% -> " + (l_warn*100).toFixed(1) + "% (needs much darker)");
console.log("  success: 55% -> " + (l_success*100).toFixed(1) + "% (needs slightly darker)");
console.log("  danger: 55% -> " + (l_danger*100).toFixed(1) + "% ✓");

console.log("\n=== Suggested DESIGN.md corrections ===");
console.log(`  --ink: oklch(${Math.round(l_ink*100)}% 0.012 250)`);
console.log(`  --ink-soft: oklch(${Math.round(l_ink_soft*100)}% 0.012 250)`);
console.log(`  --ink-faint: oklch(40% 0.008 250)  /* for large text only */`);
console.log(`  --accent: oklch(${Math.round(l_accent*100)}% 0.18 255)`);
console.log(`  --warn: oklch(${Math.round(l_warn*100)}% 0.18 85)`);
console.log(`  --success: oklch(${Math.round(l_success*100)}% 0.18 140)`);
console.log(`  --danger: oklch(${Math.round(l_danger*100)}% 0.22 25)  /* unchanged */`);
