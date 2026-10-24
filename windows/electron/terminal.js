// The shell's terminal, kept apart from the window so it can be tested on its own: one
// ConPTY per connection, in the folder the page asked for, at the size the page draws.
// (The Mac's TerminalSession.swift starts the login shell in the project folder too.)
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const MAX_REASON = 120;
const CONNECTING = 0;
const OPEN = 1;

/// A folder that exists, or the next one that does. A project can be deleted while the
/// page still names it; the terminal then starts at home rather than not at all.
function usableDirectory(...candidates) {
  for (const candidate of candidates) {
    if (typeof candidate !== 'string' || !candidate) continue;
    try {
      if (fs.statSync(candidate).isDirectory()) return candidate;
    } catch { /* not there: try the next */ }
  }
  return os.homedir();
}

function terminalEnvironment(environment) {
  return {
    ...environment,
    TERM: 'xterm-256color',
    COLORTERM: 'truecolor',
    TERM_PROGRAM: 'KuvoCode',
  };
}

/// The shells to try, in order. Windows 11 has Windows PowerShell everywhere; PowerShell 7
/// is used when it is installed, and cmd.exe is the last resort.
function shellCandidates(platform, environment) {
  if (platform === 'win32') {
    const systemRoot = environment.SystemRoot || environment.SYSTEMROOT || 'C:\\Windows';
    const programFiles = environment.ProgramFiles || 'C:\\Program Files';
    const candidates = [];
    // PowerShell 7 when it is really there, then the Windows PowerShell every Windows
    // has, then the command processor. Trying a missing pwsh.exe first would make the
    // terminal fail on machines that do not have it.
    const pwsh = path.join(programFiles, 'PowerShell', '7', 'pwsh.exe');
    if (fs.existsSync(pwsh)) candidates.push({ command: pwsh, args: ['-NoLogo'] });
    candidates.push({ command: path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), args: ['-NoLogo'] });
    candidates.push({ command: environment.ComSpec || path.join(systemRoot, 'System32', 'cmd.exe'), args: [] });
    return candidates;
  }
  return [{ command: environment.SHELL || '/bin/sh', args: ['-l'] }];
}

function integerIn(value, minimum, maximum, fallback) {
  const number = Number.parseInt(value, 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(maximum, Math.max(minimum, number));
}

/// A terminal's place in a WebSocket query: the folder, and the grid the page drew.
function terminalRequest(url, fallbackDirectory) {
  let params;
  try {
    params = new URL(url || '/', 'ws://127.0.0.1').searchParams;
  } catch {
    params = new URLSearchParams();
  }
  return {
    directory: usableDirectory(params.get('cwd'), typeof fallbackDirectory === 'function' ? fallbackDirectory() : fallbackDirectory),
    cols: integerIn(params.get('cols'), 2, 1000, 80),
    rows: integerIn(params.get('rows'), 1, 500, 24),
  };
}

function reasonBytes(text) {
  let reason = String(text || 'Terminal closed.');
  while (Buffer.byteLength(reason, 'utf8') > MAX_REASON) reason = reason.slice(0, -1);
  return reason;
}

function close(ws, code, reason) {
  try {
    if (ws.readyState === CONNECTING || ws.readyState === OPEN) ws.close(code, reasonBytes(reason));
  } catch { /* already gone */ }
}

/// Starts the local terminal server. The page connects with `cwd`, `cols` and `rows`, so the
/// first prompt is already in the project and at the right size; nothing has to be resized
/// after it has printed.
function startTerminalServer({
  WebSocketServer,
  pty,
  cwd = os.homedir(),
  env = process.env,
  platform = process.platform,
} = {}) {
  if (!WebSocketServer) return Promise.reject(new Error('the terminal needs ws'));
  const sessions = new Set();
  let closing = false;

  return new Promise((resolve, reject) => {
    const server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
    server.once('error', reject);
    server.once('listening', () => {
      const port = server.address().port;
      server.on('connection', (ws, request) => {
        if (closing) { close(ws, 1001, 'Kuvo Code is closing.'); return; }
        // The page is the harness on this machine. A WebSocket opened by a random web
        // page must not be handed a shell.
        const origin = request && request.headers && request.headers.origin;
        if (origin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(origin)) {
          close(ws, 1008, 'The terminal is only available to Kuvo Code.');
          return;
        }
        if (!pty) { close(ws, 1011, 'The terminal needs node-pty, which this build does not carry.'); return; }

        const { directory, cols, rows } = terminalRequest(request && request.url, cwd);
        let term = null;
        let lastError = null;
        for (const candidate of shellCandidates(platform, env)) {
          try {
            term = pty.spawn(candidate.command, candidate.args, {
              name: 'xterm-256color',
              cols,
              rows,
              cwd: directory,
              env: terminalEnvironment(env),
            });
            break;
          } catch (error) {
            lastError = error;
          }
        }
        if (!term) {
          close(ws, 1011, `The terminal could not start: ${String(lastError && lastError.message || lastError || 'no shell')}`);
          return;
        }

        const session = { ws, term };
        sessions.add(session);
        let gone = false;
        const finish = (code, reason) => {
          if (gone) return;
          gone = true;
          sessions.delete(session);
          close(ws, code, reason);
        };

        term.onData((data) => {
          try { ws.send(data); } catch { /* the page went away */ }
        });
        term.onExit(({ exitCode }) => {
          finish(1000, `Terminal exited (${exitCode ?? 0}).`);
        });
        ws.on('message', (raw) => {
          if (gone) return;
          const text = raw.toString();
          try {
            const message = JSON.parse(text);
            if (message && message.type === 'resize') {
              const columns = integerIn(message.cols, 2, 1000, cols);
              const lines = integerIn(message.rows, 1, 500, rows);
              try { term.resize(columns, lines); } catch { /* the shell went away */ }
              return;
            }
          } catch { /* not JSON: it is typed input */ }
          try { term.write(text); } catch { /* the shell went away */ }
        });
        const stop = () => {
          sessions.delete(session);
          try { term.kill(); } catch { /* already exited */ }
        };
        ws.on('close', stop);
        ws.on('error', stop);
      });
      resolve({
        server,
        port,
        close() {
          closing = true;
          for (const session of sessions) {
            try { session.term.kill(); } catch { /* already exited */ }
            try { session.ws.close(1001, 'Kuvo Code is closing.'); } catch { /* already gone */ }
          }
          sessions.clear();
          return new Promise((done) => server.close(() => done()));
        },
      });
    });
  });
}

module.exports = {
  startTerminalServer,
  terminalRequest,
  terminalEnvironment,
  shellCandidates,
  usableDirectory,
  reasonBytes,
};
