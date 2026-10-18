// Smoke-tests a built shell: starts it in --smoke mode, waits for it to report success, and
// fails the run if it doesn't. Used by CI on the unpacked Windows build.
//
//   node smoke.js <path-to-exe> [<path-to-exe> ...]

const { spawn } = require('child_process');
const fs = require('fs');

const exes = process.argv.slice(2);
if (exes.length === 0) {
  console.error('usage: node smoke.js <exe> [<exe> ...]');
  process.exit(2);
}

(async () => {
  for (const exe of exes) {
    if (!fs.existsSync(exe)) { console.error(`missing: ${exe}`); process.exit(1); }
    const child = spawn(exe, ['--smoke'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (chunk) => { output += chunk; process.stdout.write(chunk); });
    child.stderr.on('data', (chunk) => { process.stderr.write(chunk); });
    const code = await new Promise((resolve) => {
      const timer = setTimeout(() => { child.kill(); resolve(124); }, 90000);
      child.on('exit', (c) => { clearTimeout(timer); resolve(c ?? 0); });
    });
    if (code !== 0) {
      console.error(`FAIL: ${exe} exited ${code}\n${output}`);
      process.exit(1);
    }
    console.log(`ok: ${exe}`);
  }
})();
