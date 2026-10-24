// A machine reached over SSH: validate the destination, then ask it to say hello
// without blocking the shell's main process.
//
// The destination is one argv item, never a shell string. A value that starts with
// "-" would be read by ssh as an option, so it is rejected before ssh is started.

const { execFile } = require("child_process");

const DESTINATION = /^(?:[A-Za-z0-9._-]+@)?(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._:%-]+)$/;

/// True for `host`, `user@host`, an IPv4 address, or a bracketed/unbracketed IPv6
/// address. No spaces, no options, no shell punctuation.
function validDestination(value) {
  if (typeof value !== "string") return false;
  const target = value.trim();
  if (!target || target.length > 255 || target.startsWith("-")) return false;
  return DESTINATION.test(target);
}

/// Run `ssh <destination> echo ok`. Resolves with `{ ok, output }` or
/// `{ ok: false, error }`; it never rejects, because the page draws the answer.
function checkDestination(destination, { exec = execFile, timeout = 10000 } = {}) {
  const target = typeof destination === "string" ? destination.trim() : "";
  if (!validDestination(target)) {
    return Promise.resolve({
      ok: false,
      error: "Enter a host or user@host, without spaces or options.",
    });
  }

  return new Promise(resolve => {
    exec(
      "ssh",
      [
        "-o", "ConnectTimeout=5",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        target,
        "echo", "ok",
      ],
      { timeout, windowsHide: true, maxBuffer: 64 * 1024 },
      (error, stdout, stderr) => {
        if (error) {
          const detail = String(stderr || error.message || error).trim();
          resolve({ ok: false, error: detail || "ssh could not reach the machine." });
          return;
        }
        const output = String(stdout ?? "").trim();
        if (output === "ok") resolve({ ok: true, output });
        else resolve({ ok: false, output, error: `The machine answered "${output || "nothing"}".` });
      },
    );
  });
}

module.exports = { validDestination, checkDestination };
