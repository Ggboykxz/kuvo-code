// Kuvo Code's Windows shell: a native window around the harness, which already knows how to
// install and run the engine. This process owns the window, the tray, the terminal (ConPTY)
// and the lifecycle.
const { app, BrowserWindow, Tray, Menu, nativeImage, dialog, globalShortcut, Notification, powerSaveBlocker, shell, ipcMain } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { RELEASES_API, pickRelease } = require('./update-check.js');
let pty = null;
try { pty = require('node-pty'); } catch (error) { console.error('node-pty unavailable:', error && error.message); }
let WebSocketServer = null;
try { WebSocketServer = require('ws').WebSocketServer; } catch (error) { console.error('ws unavailable:', error && error.message); }

const isDev = !app.isPackaged;
const userData = app.getPath('userData');
const configPath = path.join(userData, 'config.json');

function loadConfig() { try { return JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch { return {}; } }
function saveConfig(config) { fs.mkdirSync(userData, { recursive: true }); fs.writeFileSync(configPath, JSON.stringify(config, null, 2)); }

// The app's own icon, taken from the macOS build (windows/tools/make-icon.py). The window
// and the tray wear it; Windows takes the executable's icon from build/icon.ico.
const ICON_FILE = path.join(__dirname, 'build', 'icon.png');
const ICON = fs.existsSync(ICON_FILE)
  ? nativeImage.createFromPath(ICON_FILE)
  : nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAPElEQVR4nO3OMQ0AIAwAsDnBDwd+cIE91IAIQgZJj/6N0vrKFAICAs8H6phHBAQEBAQEBP4P3CYgIJAe2LDUYXkB9p2aAAAAAElFTkSuQmCC');

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
    // The page draws its own title-bar strip (`.titlebar-drag`); Windows' native
    // controls stay, like the Mac app's hidden-inset title bar.
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: '#00000000', symbolColor: '#888888', height: 38 },
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  const fullUrl = `${url}${url.includes('?') ? '&' : '?'}terminalPort=${terminalPort}&shell=1`;
  mainWindow.loadURL(fullUrl);
  mainWindow.once('ready-to-show', () => mainWindow.show());
  // The settings page can change these; the window coming forward is when they are read.
  mainWindow.on('focus', () => applyShellPreferences());
  mainWindow.on('close', (event) => {
    if (!quitting) { event.preventDefault(); mainWindow.hide(); }
  });
}

// The recent projects: the harness's own list, so the sidebar and the tray's menu are
// one list (the Mac keeps one list of folders, too).
const recentFile = () => path.join(os.homedir(), '.kuvo-code', 'recent-projects.json');
function recentProjects() {
  try {
    const list = JSON.parse(fs.readFileSync(recentFile(), 'utf8'));
    return Array.isArray(list) ? list.slice(0, 8) : [];
  } catch { return []; }
}

function rememberProject(project) {
  try {
    fs.mkdirSync(path.dirname(recentFile()), { recursive: true });
    const next = [project, ...recentProjects().filter(item => item !== project)].slice(0, 8);
    fs.writeFileSync(recentFile(), JSON.stringify(next, null, 2));
  } catch {}
  const config = loadConfig();
  config.project = project;
  saveConfig(config);
}

async function switchProject(project) {
  if (harness) { try { harness.kill(); } catch {} harness = null; }
  const url = await startHarness(project);
  rememberProject(project);
  if (mainWindow) mainWindow.loadURL(`${url}${url.includes('?') ? '&' : '?'}terminalPort=${terminalPort}&shell=1`);
}

// What the settings page asks for: staying awake, and starting at login.
let awakeBlocker = null;
function applyShellPreferences() {
  const config = loadConfig();
  try { app.setLoginItemSettings({ openAtLogin: Boolean(config.autoStart) }); } catch {}
  if (config.keepAwake && !awakeBlocker) {
    try { awakeBlocker = powerSaveBlocker.start('prevent-display-sleep'); } catch { awakeBlocker = null; }
  } else if (!config.keepAwake && awakeBlocker) {
    try { awakeBlocker.stop(); } catch {}
    awakeBlocker = null;
  }
}

/// The app's own menus, the Mac's (NativeMenu.swift:5-165): a real menu bar, with the
/// items the Mac has, and the keys beside them. The items that act on the conversation
/// ask the page to do it, by the shortcut the Mac uses.
function applicationMenu() {
  const ask = id => () => { if (mainWindow) mainWindow.webContents.send("kuvo:menu", id); };
  const template = [
    {
      label: "Kuvo Code",
      submenu: [
        { role: "about" },
        { type: "separator" },
        { label: "Start at login", type: "checkbox", checked: loadConfig().autoStart === true, click: item => {
          const next = loadConfig(); next.autoStart = item.checked; saveConfig(next);
          app.setLoginItemSettings({ openAtLogin: item.checked });
        } },
        { label: "Automatic updates", type: "checkbox", checked: loadConfig().autoUpdate !== false, click: item => {
          const next = loadConfig(); next.autoUpdate = item.checked; saveConfig(next);
          if (item.checked) void checkForUpdates({ quiet: true });
        } },
        { label: "Check for Updates…", click: () => { void checkForUpdates(); } },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    {
      label: "File",
      submenu: [
        { label: "New Session", accelerator: "CmdOrCtrl+N", click: ask("new-session") },
        { label: "Open Folder…", accelerator: "CmdOrCtrl+O", click: ask("open-folder") },
        { label: "Export Conversation as Markdown", accelerator: "CmdOrCtrl+S", click: ask("save") },
        { type: "separator" },
        { role: "close" },
      ],
    },
    {
      label: "Edit",
      submenu: [
        { role: "undo" }, { role: "redo" }, { type: "separator" },
        { role: "cut" }, { role: "copy" }, { role: "paste" }, { role: "selectAll" },
      ],
    },
    {
      label: "View",
      submenu: [
        { label: "Command Palette", accelerator: "CmdOrCtrl+K", click: ask("palette") },
        { label: "Settings…", accelerator: "CmdOrCtrl+,", click: ask("settings") },
        { type: "separator" },
        { label: "Show Panel", accelerator: "Alt+CmdOrCtrl+0", click: ask("panel") },
        { label: "Show Sessions", accelerator: "CmdOrCtrl+0", click: ask("sidebar") },
        { type: "separator" },
        { role: "reload" }, { role: "toggleDevTools" }, { type: "separator" },
        { role: "resetZoom" }, { role: "zoomIn" }, { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" },
      ],
    },
    { label: "Window", submenu: [{ role: "minimize" }, { role: "zoom" }] },
    {
      label: "Help",
      submenu: [
        { label: "Kuvo Code on the web", click: () => shell.openExternal("https://www.kuvo.run/code/") },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
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
    items.push({ label: 'Automatic updates', type: 'checkbox', checked: config.autoUpdate !== false, click: (item) => {
      const next = loadConfig(); next.autoUpdate = item.checked; saveConfig(next);
      if (item.checked) void checkForUpdates({ quiet: true });
    } });
    items.push({ label: 'Check for updates', click: () => { void checkForUpdates(); } });
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

// The page's double-click on the title bar (Card.swift:186-198 — the system preference
// decides; on Windows, that is the window maximised).
// The project the app switched to (SidebarView.swift:194): the shell remembers it, so
// the app opens there next time.
ipcMain.on("kuvo:remember-project", (_event, folder) => {
  if (typeof folder === 'string' && folder) rememberProject(folder);
});

ipcMain.on("kuvo:maximize", () => {
  if (!mainWindow) return;
  if (mainWindow.isMaximized()) mainWindow.unmaximize();
  else mainWindow.maximize();
});

function shutdown() {
  if (terminalServer) { try { terminalServer.close(); } catch {} terminalServer = null; }
  if (harness) { try { harness.kill(); } catch {} harness = null; }
}

// ---- The updates ----
//
// Our releases are prereleases with a tag of their own, and electron-updater's GitHub
// provider looks for another kind of release — so the shell asks GitHub itself, compares the
// versions, and offers the installer. The keys are ours: the installer is the portable one's
// bigger brother, and it replaces what is installed.

async function checkForUpdates({ quiet = false } = {}) {
  try {
    const response = await fetch(RELEASES_API, { headers: { 'user-agent': 'Kuvo-Code' } });
    if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
    const releases = await response.json();
    const update = pickRelease(releases, app.getVersion());
    if (!update) {
      if (!quiet) {
        const message = { type: 'info', title: 'Kuvo Code', message: `Kuvo Code ${app.getVersion()} is the latest.` };
        if (mainWindow) dialog.showMessageBox(mainWindow, message);
        else dialog.showMessageBox(message);
      }
      return null;
    }
    if (quiet) {
      // On startup, a note in the corner — not a question that waits for an answer. Clicking
      // it asks the question.
      try {
        const note = new Notification({ title: 'Kuvo Code', body: `Version ${update.version} is available.` });
        note.on('click', () => { void checkForUpdates(); });
        note.show();
      } catch {}
      return update;
    }
    const question = {
      type: 'info', buttons: ['Download and install', 'Later'], defaultId: 0,
      title: 'A new version', message: `Kuvo Code ${update.version} is available. Download it now?`,
    };
    const choice = mainWindow ? dialog.showMessageBoxSync(mainWindow, question) : dialog.showMessageBoxSync(question);
    if (choice !== 0) return update;
    await downloadAndRun(update);
    return update;
  } catch (error) {
    if (!quiet) dialog.showErrorBox('Kuvo Code', `The update check failed: ${String(error && error.message || error)}`);
    return null;
  }
}

async function downloadAndRun(update) {
  const target = path.join(os.tmpdir(), update.name);
  const response = await fetch(update.url, { headers: { 'user-agent': 'Kuvo-Code' } });
  if (!response.ok) throw new Error(`the download failed (${response.status})`);
  fs.writeFileSync(target, Buffer.from(await response.arrayBuffer()));
  const failure = await shell.openPath(target);
  if (failure) throw new Error(failure);
}

app.whenReady().then(async () => {
  try {
    const cfg = loadConfig();
    if (cfg.autoStart) app.setLoginItemSettings({ openAtLogin: true });
    applyShellPreferences();
    globalShortcut.register('CommandOrControl+Shift+K', toggleWindow);
    applicationMenu();
    // Auto-update on startup, unless the user turned it off: a note, not a question.
    if (cfg.autoUpdate !== false) {
      void checkForUpdates({ quiet: true });
      // And again a few times a day, so a version published while the app is open is
      // still found — the Mac app's updater checks in the background too.
      setInterval(() => {
        if (loadConfig().autoUpdate !== false) void checkForUpdates({ quiet: true });
      }, 6 * 60 * 60 * 1000);
    }
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
  } catch (error) {
    dialog.showErrorBox('Kuvo Code', String(error && error.message || error));
    shutdown();
    app.quit();
  }
});

app.on('window-all-closed', () => { /* stay alive in the tray */ });
app.on('before-quit', () => { quitting = true; });
app.on('will-quit', () => { globalShortcut.unregisterAll(); shutdown(); });

