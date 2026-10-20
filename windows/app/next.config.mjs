// The window, built by Next.js: one page, exported as static files the harness serves.
//
//   output: "export" — the app talks to the engine over the harness's own HTTP API, so
//   there is nothing to render on a server: the exported files are the whole app. That
//   keeps the packed executable a single file, and the app working with no network.
//
//   externalDir — the Mac's stylesheet lives with the harness, and is imported from there.

import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** @type {import('next').NextConfig} */
const config = {
  output: "export",
  reactStrictMode: true,
  trailingSlash: true,
  images: { unoptimized: true },
  experimental: { externalDir: true },
  // The app's own code reaches outside its folder for the transcript reducer, which the
  // harness serves as well; the bundler's root is the windows/ folder, so it may.
  turbopack: { root: path.join(here, "..") },
};

export default config;
