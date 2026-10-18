// Kuvo Code's Windows shell: a native window around the harness, which already knows how to
// install and run the engine. This process owns the window, the tray, the terminal (ConPTY)
// and the lifecycle.
const { app, BrowserWindow, Tray, Menu, nativeImage, dialog, globalShortcut, Notification } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { autoUpdater } = require('electron-updater');
let pty = null;
try { pty = require('node-pty'); } catch (error) { console.error('node-pty unavailable:', error && error.message); }
let WebSocketServer = null;
try { WebSocketServer = require('ws').WebSocketServer; } catch (error) { console.error('ws unavailable:', error && error.message); }

const isDev = !app.isPackaged;
const userData = app.getPath('userData');
const configPath = path.join(userData, 'config.json');

function loadConfig() { try { return JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch { return {}; } }
function saveConfig(config) { fs.mkdirSync(userData, { recursive: true }); fs.writeFileSync(configPath, JSON.stringify(config, null, 2)); }

const ICON = nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAPElEQVR4nO3OMQ0AIAwAsDnBDwd+cIE91IAIQgZJj/6N0vrKFAICAs8H6phHBAQEBAQEBP4P3CYgIJAe2LDUYXkB9p2aAAAAAElFTkSuQmCC');

let harness = null;
let harnessUrl = null;
let terminalPort = 0;
let terminalServer = null;
let mainWindow = null;
let tray = null;
let quitting = false;

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) { mainWindow.show(); mainWindow.focus(); }
  });
}

function harnessCommand(project, port) {
  if (isDev) {
    return { command: process.execPath, args: [path.join(__dirname, '..', 'harness', 'server.mjs'), '--project', project, '--port', String(port)] };
  }
  return { command: path.join(process.resourcesPath, 'harness', 'kuvo-windows-harness.exe'), args: ['--project', project, '--port', String(port)] };
}

async function startHarness(project) {
  const cfg = loadConfig();
  const folder = project || cfg.project || os.homedir();
  const { command, args } = harnessCommand(folder, 0);
  harness = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  harness.on('exit', (code) => {
    if (quitting) return;
    try { new Notification({ title: 'Kuvo Code', body: `The harness stopped (exit ${code ?? 0}).` }).show(); } catch {}
  });
  const url = await new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error('the harness did not come up in time')), 60000);
    harness.stdout.on('data', (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/at (http:\/\/\S+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    harness.stderr.on('data', (chunk) => process.stderr.write(chunk));
    harness.on('exit', (code) => { clearTimeout(timer); reject(new Error(`the harness stopped before it was up (exit ${code})`)); });
  });
  harnessUrl = url;
  if (project) { const c = loadConfig(); c.project = project; saveConfig(c); }
  return url;
}

function startTerminalServer() {
  if (!WebSocketServer) return Promise.resolve(0);
  return new Promise((resolve) => {
    terminalServer = new WebSocketServer({ port: 0, host: '127.0.0.1' }, () => {
      terminalPort = terminalServer.address().port;
      resolve(terminalPort);
    });
    terminalServer.on('connection', (ws) => {
      if (!pty) { try { ws.close(); } catch {} return; }
      const shell = process.platform === 'win32' ? 'powershell.exe' : (process.env.SHELL || '/bin/bash');
      const term = pty.spawn(shell, [], { name: 'xterm-color', cols: 80, rows: 24, cwd: os.homedir(), env: process.env });
      term.onData((data) => { try { ws.send(data); } catch {} });
      ws.on('message', (raw) => {
        const text = raw.toString();
        try {
          const message = JSON.parse(text);
          if (message && message.type === 'resize' && message.cols && message.rows) {
            term.resize(message.cols, message.rows);
            return;
          }
        } catch { /* not JSON: treat as input */ }
        term.write(text);
      });
      ws.on('close', () => { try { term.kill(); } catch {} });
      term.onExit(() => { try { ws.close(); } catch {} });
    });
  });
}

function createWindow(url) {
  mainWindow = new BrowserWindow({
    width: 1280, height: 820, minWidth: 900, minHeight: 600,
    title: 'Kuvo Code', show: false, icon: ICON,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  const fullUrl = `${url}${url.includes('?') ? '&' : '?'}terminalPort=${terminalPort}`;
  mainWindow.loadURL(fullUrl);
  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.on('close', (event) => {
    if (!quitting) { event.preventDefault(); mainWindow.hide(); }
  });
}

function recentProjects() {
  const config = loadConfig();
  return Array.isArray(config.recentProjects) ? config.recentProjects.slice(0, 6) : [];
}

function rememberProject(project) {
  const config = loadConfig();
  const list = Array.isArray(config.recentProjects) ? config.recentProjects : [];
  const next = [project, ...list.filter(item => item !== project)].slice(0, 6);
  config.recentProjects = next;
  saveConfig(config);
}

async function switchProject(project) {
  if (harness) { try { harness.kill(); } catch {} harness = null; }
  const url = await startHarness(project);
  rememberProject(project);
  if (mainWindow) mainWindow.loadURL(`${url}${url.includes('?') ? '&' : '?'}terminalPort=${terminalPort}`);
}

function createTray() {
  tray = new Tray(ICON);
  tray.setToolTip('Kuvo Code');
  const rebuild = () => {
    const items = [
      { label: 'Show Kuvo Code', click: () => { if (mainWindow) { mainWindow.show(); mainWindow.focus(); } } },
      { type: 'separator' },
    ];
    const recent = recentProjects();
    if (recent.length) {
      items.push({ label: 'Recent projects', submenu: recent.map(project => ({
        label: project,
        click: () => switchProject(project).catch(error => dialog.showErrorBox('Kuvo Code', String(error && error.message || error))),
      })) });
      items.push({ type: 'separator' });
    }
    const config = loadConfig();
    items.push({ label: 'Start at login', type: 'checkbox', checked: !!config.autoStart, click: (item) => {
      const next = loadConfig(); next.autoStart = item.checked; saveConfig(next);
      app.setLoginItemSettings({ openAtLogin: item.checked });
    } });
    items.push({ label: 'Check for updates', click: () => { try { autoUpdater.checkForUpdates(); } catch {} } });
    items.push({ type: 'separator' });
    items.push({ label: 'Quit', click: () => { quitting = true; app.quit(); } });
    tray.setContextMenu(Menu.buildFromTemplate(items));
  };
  rebuild();
  tray.on('click', () => { if (mainWindow) { mainWindow.show(); mainWindow.focus(); } });
  // Rebuild the menu when the window is shown, so recent projects stay fresh.
  app.on('browser-window-focus', rebuild);
}

function toggleWindow() {
  if (!mainWindow) return;
  if (mainWindow.isVisible()) mainWindow.hide();
  else { mainWindow.show(); mainWindow.focus(); }
}

function shutdown() {
  if (terminalServer) { try { terminalServer.close(); } catch {} terminalServer = null; }
  if (harness) { try { harness.kill(); } catch {} harness = null; }
}

app.whenReady().then(async () => {
  try {
    const cfg = loadConfig();
    if (cfg.autoStart) app.setLoginItemSettings({ openAtLogin: true });
    globalShortcut.register('CommandOrControl+Shift+K', toggleWindow);
    if (process.argv.includes('--smoke')) {
      const url = await startHarness();
      const response = await fetch(`${url}api/state`, { signal: AbortSignal.timeout(10000) });
      const state = await response.json();
      if (response.status !== 200 || state.engine.status !== 'stopped') throw new Error(`unexpected state: ${JSON.stringify(state)}`);
      console.log(`ok: Kuvo Code started, state is ${JSON.stringify(state)}`);
      shutdown();
      app.exit(0);
      return;
    }
    await startTerminalServer();
    const url = await startHarness();
    rememberProject(loadConfig().project || os.homedir());
    createWindow(url);
    createTray();
    try {
      autoUpdater.allowPrerelease = true;
      autoUpdater.checkForUpdatesAndNotify();
    } catch {}
  } catch (error) {
    dialog.showErrorBox('Kuvo Code', String(error && error.message || error));
    shutdown();
    app.quit();
  }
});

app.on('window-all-closed', () => { /* stay alive in the tray */ });
app.on('before-quit', () => { quitting = true; });
app.on('will-quit', () => { globalShortcut.unregisterAll(); shutdown(); });

autoUpdater.on('update-downloaded', () => {
  if (!mainWindow) return;
  const choice = dialog.showMessageBoxSync(mainWindow, {
    type: 'info', buttons: ['Restart now', 'Later'], defaultId: 0,
    title: 'Update ready', message: 'A new version of Kuvo Code has been downloaded. Restart to install it?',
  });
  if (choice === 0) autoUpdater.quitAndInstall();
});
autoUpdater.on('error', () => { /* updates are optional; stay quiet */ });
