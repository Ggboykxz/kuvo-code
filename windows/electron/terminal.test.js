// The real terminal, on the same machine that builds the app: node-pty and ConPTY (or a
// Unix pty in development), the WebSocket the page speaks, a folder, a grid, an exit and
// a second shell. This is deliberately not a mock: the Windows release gate runs it so a
// packaged terminal that cannot start cannot ship.
//
//   npm run test:terminal

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const { WebSocket } = require('ws');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const { startTerminalServer } = require('./terminal.js');

const isWindows = process.platform === 'win32';

/// A command whose typed text does not contain the marker it prints, so seeing the
/// marker proves the shell ran it rather than merely echoing the line.
function markerCommand(marker) {
  const split = marker.length - 2;
  return isWindows
    ? `Write-Output ('${marker.slice(0, split)}' + '${marker.slice(split)}')`
    : `printf '%s\\n' '${marker.slice(0, split)}''${marker.slice(split)}'`;
}

function cwdCommand() {
  return isWindows
    ? "Write-Output ('KUVO_' + 'CWD:' + (Get-Location).Path)"
    : "printf '%s%s\\n' 'KUVO_' \"CWD:$PWD\"";
}

function exitCommand() {
  return "exit\r";
}

function connect(port, directory, cols, rows) {
  const url = `ws://127.0.0.1:${port}/?cwd=${encodeURIComponent(directory)}&cols=${cols}&rows=${rows}`;
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    let output = "";
    let settled = false;
    const waiters = [];
    const closed = new Promise(done => {
      socket.once('close', (code, reason) => done({ code, reason: reason.toString() }));
    });

    const check = () => {
      for (let index = waiters.length - 1; index >= 0; index -= 1) {
        const waiter = waiters[index];
        const found = typeof waiter.wanted === "string" ? output.includes(waiter.wanted) : waiter.wanted.test(output);
        if (found) {
          waiters.splice(index, 1);
          clearTimeout(waiter.timer);
          waiter.resolve(output);
        }
      }
    };

    socket.on('message', data => {
      output += data.toString();
      check();
    });
    socket.once('error', error => { if (!settled) reject(error); });
    socket.once('open', () => {
      settled = true;
      resolve({
        socket,
        closed,
        output: () => output,
        send: text => socket.send(text),
        waitFor(wanted, timeout = 20000) {
          if (typeof wanted === "string" ? output.includes(wanted) : wanted.test(output)) return Promise.resolve(output);
          return new Promise((done, fail) => {
            const waiter = {
              wanted,
              resolve: done,
              timer: setTimeout(() => {
                const position = waiters.indexOf(waiter);
                if (position >= 0) waiters.splice(position, 1);
                fail(new Error(`timed out waiting for ${wanted}; the terminal said:\n${output}`));
              }, timeout),
            };
            waiters.push(waiter);
          });
        },
      });
    });
  });
}

test("the real shell starts in the project, answers, resizes, exits and starts again", { timeout: 60000 }, async t => {
  const handle = await startTerminalServer({
    WebSocketServer,
    pty,
    cwd: process.cwd(),
    env: process.env,
    platform: process.platform,
  });
  t.after(async () => { await handle.close(); });

  const first = await connect(handle.port, process.cwd(), 101, 31);
  t.after(() => { try { first.socket.close(); } catch { /* already closed */ } });

  first.send(`${markerCommand("KUVO_TERMINAL_READY")}\r`);
  await first.waitFor("KUVO_TERMINAL_READY");

  first.send(`${cwdCommand()}\r`);
  const located = await first.waitFor("KUVO_CWD:");
  assert.match(located, new RegExp(`KUVO_CWD:${process.cwd().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));

  // A resize is a control message, not text typed into the shell.
  first.send(JSON.stringify({ type: "resize", cols: 77, rows: 21 }));
  first.send(`${markerCommand("KUVO_TERMINAL_RESIZED")}\r`);
  await first.waitFor("KUVO_TERMINAL_RESIZED");

  first.send(exitCommand());
  const ended = await first.closed;
  assert.equal(ended.code, 1000);

  // The page's Restart opens another connection; it must get a working shell rather
  // than inheriting the dead one.
  const second = await connect(handle.port, process.cwd(), 90, 24);
  t.after(() => { try { second.socket.close(); } catch { /* already closed */ } });
  second.send(`${markerCommand("KUVO_TERMINAL_AGAIN")}\r`);
  await second.waitFor("KUVO_TERMINAL_AGAIN");

  second.send(exitCommand());
  await second.closed;
});

test("a bad folder still gets a shell in a folder that exists", { timeout: 30000 }, async t => {
  const handle = await startTerminalServer({
    WebSocketServer,
    pty,
    cwd: process.cwd(),
    env: process.env,
    platform: process.platform,
  });
  t.after(async () => { await handle.close(); });

  const missing = path.join(process.cwd(), `kuvo-missing-${process.pid}`);
  const session = await connect(handle.port, missing, 80, 24);
  t.after(() => { try { session.socket.close(); } catch { /* already closed */ } });
  session.send(`${markerCommand("KUVO_TERMINAL_HOME")}\r`);
  await session.waitFor("KUVO_TERMINAL_HOME");
  session.send(exitCommand());
  await session.closed;
});
