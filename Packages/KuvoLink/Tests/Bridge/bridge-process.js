// The coding agents' bridge, as the link finds it: a live process whose command line names it.
// It says it is up before this returns, so a check made right after spawning can't read the
// command line the child inherited from the test runner and take the bridge for absent.
import { spawn } from "node:child_process";

export async function agentsBridge(t) {
  const child = spawn(
    process.execPath,
    ["-e", "process.stdout.write('up'); setInterval(() => {}, 1000)", "kuvo-agents"],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  t.after(() => child.kill());
  await new Promise((resolve, reject) => {
    child.stdout.once("data", resolve);
    child.once("error", reject);
    child.once("exit", code => reject(new Error(`the bridge process stopped before it ran (${code})`)));
  });
  return child;
}
