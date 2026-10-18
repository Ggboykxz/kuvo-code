// Kuvo Code's Windows shell: a native window around the harness, which already knows how to
// install and run the engine. This process only owns the window, the tray and the lifecycle.
const { app, BrowserWindow, Tray, Menu, nativeImage, dialog } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { autoUpdater } = require('electron-updater');

const isDev = !app.isPackaged;
const userData = app.getPath('userData');
const configPath = path.join(userData, 'config.json');

function loadConfig() { try { return JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch { return {}; } }
function saveConfig(config) { fs.mkdirSync(userData, { recursive: true }); fs.writeFileSync(configPath, JSON.stringify(config, null, 2)); }

const ICON = nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAPElEQVR4nO3OMQ0AIAwAsDnBDwd+cIE91IAIQgZJj/6N0vrKFAICAs8H6phHBAQEBAQEBP4P3CYgIJAe2LDUYXkB9p2aAAAAAElFTkSuQmCC');

let harness = null;
let harnessUrl = null;
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
  const binary = path.join(process.resourcesPath, 'harness', 'kuvo-windows-harness.exe');
  return { command: binary, args: ['--project', project, '--port', String(port)] };
}

async function startHarness() {
  const config = loadConfig();
  const project = config.project || os.homedir();
  const { command, args } = harnessCommand(project, 0);
  harness = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
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
  return url;
}

function createWindow(url) {
  mainWindow = new BrowserWindow({
    width: 1280, height: 820, minWidth: 900, minHeight: 600,
    title: 'Kuvo Code', show: false, icon: ICON,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  mainWindow.loadURL(url);
  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.on('close', (event) => {
    if (!quitting) { event.preventDefault(); mainWindow.hide(); }
  });
}

function createTray() {
  tray = new Tray(ICON);
  tray.setToolTip('Kuvo Code');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Show Kuvo Code', click: () => { if (mainWindow) { mainWindow.show(); mainWindow.focus(); } } },
    { type: 'separator' },
    { label: 'Quit', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('click', () => { if (mainWindow) { mainWindow.show(); mainWindow.focus(); } });
}

function shutdown() {
  if (harness) { try { harness.kill(); } catch {} harness = null; }
}

app.whenReady().then(async () => {
  try {
    // Smoke mode: start, check, exit — used by CI to prove a packaged build.
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
    const url = await startHarness();
    createWindow(url);
    createTray();
    // Best-effort auto-update from the fork's releases.
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
app.on('will-quit', shutdown);

autoUpdater.on('update-downloaded', () => {
  if (!mainWindow) return;
  const choice = dialog.showMessageBoxSync(mainWindow, {
    type: 'info', buttons: ['Restart now', 'Later'], defaultId: 0,
    title: 'Update ready', message: 'A new version of Kuvo Code has been downloaded. Restart to install it?',
  });
  if (choice === 0) autoUpdater.quitAndInstall();
});
autoUpdater.on('error', () => { /* updates are optional; stay quiet */ });
