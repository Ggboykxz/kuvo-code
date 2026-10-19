import path from "node:path";
import { build } from "esbuild";
const here = "/home/user/myapp/windows/app";
await build({
  entryPoints: [path.join(here, "src", process.env.KUVO_ENTRY ?? "probe.tmp.tsx")],
  bundle: true, format: "iife", target: ["chrome110"],
  outfile: process.env.KUVO_OUT ?? "/tmp/opencode/page3/app.js", minify: false, sourcemap: false,
  define: { "process.env.NODE_ENV": '"production"' }, logLevel: "error",
});
console.log("built");
