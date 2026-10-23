// The SSH reachability check's contract: what a destination may look like, and the
// argv ssh is given. No real ssh runs here.

const test = require("node:test");
const assert = require("node:assert/strict");
const { validDestination, checkDestination } = require("./ssh.js");

test("accepts hosts, users, IPv4 and IPv6", () => {
  for (const value of ["server", "me@server", "me@server.example.com", "192.168.1.4", "me@192.168.1.4", "::1", "me@[::1]"]) {
    assert.equal(validDestination(value), true, value);
  }
});

test("rejects empty, option-like, spaced and shell-like destinations", () => {
  for (const value of ["", "   ", "-oProxyCommand=calc", "me@host name", "me@host;rm -rf /", "me@host$(id)", "a".repeat(256)]) {
    assert.equal(validDestination(value), false, value);
  }
});

test("runs ssh with the destination as one argv item", async () => {
  const calls = [];
  const exec = (file, args, options, callback) => {
    calls.push({ file, args, options });
    callback(null, "ok\n", "");
  };
  const result = await checkDestination("me@example.com", { exec });
  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].file, "ssh");
  assert.deepEqual(calls[0].args.slice(-3), ["me@example.com", "echo", "ok"]);
  assert.deepEqual(calls[0].args.slice(0, 6), [
    "-o", "ConnectTimeout=5",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
  ]);
  assert.equal(calls[0].options.timeout, 10000);
  assert.equal(calls[0].options.windowsHide, true);
});

test("reports ssh's own error, not a thrown exception", async () => {
  const exec = (_file, _args, _options, callback) => {
    callback(Object.assign(new Error("exit 255"), { code: 255 }), "", "Permission denied (publickey).\n");
  };
  const result = await checkDestination("me@example.com", { exec });
  assert.equal(result.ok, false);
  assert.match(result.error, /Permission denied/);
});

test("reports an answer that is not ok", async () => {
  const exec = (_file, _args, _options, callback) => callback(null, "who are you?\n", "");
  const result = await checkDestination("server", { exec });
  assert.equal(result.ok, false);
  assert.match(result.error, /who are you/);
});

test("does not start ssh for an invalid destination", async () => {
  let called = false;
  const exec = () => { called = true; };
  const result = await checkDestination("-oProxyCommand=calc", { exec });
  assert.equal(result.ok, false);
  assert.equal(called, false);
});
