// Kuvo Code's Windows shell: a native window around the harness, which already knows how to
// install and run the engine. This process owns the window, the tray, the terminal (ConPTY)
// and the lifecycle.
const { app, BrowserWindow, Tray, Menu, nativeImage, dialog, globalShortcut, Notification, powerSaveBlocker, shell, ipcMain, net } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  RELEASES_API, RELEASES_ATOM, pickRelease, parseAtom, describeError,
} = require('./update-check.js');
const { downloadInstaller, launchInstaller, sweepInstallers } = require('./update-install.js');
const { startTerminalServer: startPtyServer } = require('./terminal.js');
const { checkDestination } = require('./ssh.js');
let pty = null;
try { pty = require('node-pty'); } catch (error) { console.error('node-pty unavailable:', error && error.message); }
let WebSocketServer = null;
try { WebSocketServer = require('ws').WebSocketServer; } catch (error) { console.error('ws unavailable:', error && error.message); }

const isDev = !app.isPackaged;
const userData = app.getPath('userData');
const configPath = path.join(userData, 'config.json');
const updatesFolder = path.join(userData, 'updates');
const updateLogPath = path.join(userData, 'update.log');

// Windows shows a toast only for an app it knows by its Application User Model ID, which is
// the one the installer's shortcut carries. Without this, "Version 0.7.3 is available" is
// shown to nobody — and a quiet check looks like a check that failed.
if (process.platform === 'win32') app.setAppUserModelId('run.kuvo.code.windows');

function loadConfig() { try { return JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch { return {}; } }
function saveConfig(config) { fs.mkdirSync(userData, { recursive: true }); fs.writeFileSync(configPath, JSON.stringify(config, null, 2)); }

/// What the updater did, and why it stopped. A quiet check that fails says nothing on
/// purpose, so the log is where a failure is read afterwards.
function logUpdate(message) {
  try {
    fs.mkdirSync(userData, { recursive: true });
    fs.appendFileSync(updateLogPath, `${new Date().toISOString()} ${message}\n`);
    if (fs.statSync(updateLogPath).size > 256 * 1024) {
      const kept = fs.readFileSync(updateLogPath, 'utf8').split('\n').slice(-200).join('\n');
      fs.writeFileSync(updateLogPath, kept);
    }
  } catch {}
}
const messageOf = error => String(error && error.message || error || 'Something went wrong.');

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
let terminalCwd = os.homedir();
let mainWindow = null;
let tray = null;
let rebuildTrayMenu = null;
let quitting = false;
// What the menu bar draws from the page's state: the tab bar's own command changes its
// word, and the Appearance picker shows the one in use (KuvoCodeApp.swift:130-229).
let menuState = { tabBar: true, appearance: "system" };

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
  terminalCwd = folder;
  if (project) { const c = loadConfig(); c.project = project; saveConfig(c); }
  return url;
}

async function startTerminalServer() {
  if (!WebSocketServer) return 0;
  terminalServer = await startPtyServer({
    WebSocketServer,
    pty,
    // The page sends the folder with each connection; this is the fallback for a reload
    // that arrives before the page knows its project.
    cwd: () => terminalCwd,
    env: process.env,
  });
  terminalPort = terminalServer.port;
  return terminalPort;
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
  // The window shows the harness's page, and only it: the mouse's Back and Forward buttons
  // (and Alt+Left/Right) have nothing to go back to. The shell's own state — the title bar's
  // room for the window's controls, and the terminal's port — travels by the bridge
  // (preload.js), so even a reload keeps it (the Back button once took the query string,
  // and with it the title bar's room, away).
  mainWindow.on('app-command', (event, command) => {
    if (command === 'browser-backward' || command === 'browser-forward') event.preventDefault();
  });
  mainWindow.webContents.on('before-input-event', (event, input) => {
    if (input.alt && (input.key === 'ArrowLeft' || input.key === 'ArrowRight')) event.preventDefault();
  });
  mainWindow.webContents.on('will-navigate', (event, target) => {
    if (!harnessUrl || !target.startsWith(harnessUrl)) event.preventDefault();
  });
  // The settings page can change these; the window coming forward is when they are read.
  // The menu bar's checks come from the same file, so they are rebuilt then too.
  mainWindow.on('focus', () => { applyShellPreferences(); refreshUpdateMenus(); });
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
  terminalCwd = project;
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
  const open = url => () => { void shell.openExternal(url); };
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
        ...(pendingUpdate ? [{
          label: `Update to ${pendingUpdate.version}…`,
          enabled: !installing,
          click: () => { void askToInstall(pendingUpdate); },
        }] : []),
        { label: "Check for Updates…", click: () => { void checkForUpdates(); } },
        { type: "separator" },
        // The Mac's Settings and Accounts live in the app menu (KuvoCodeApp.swift:240-248);
        // the accounts page itself is not this client's.
        { label: "Settings…", accelerator: "CmdOrCtrl+,", click: ask("settings") },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    {
      label: "File",
      submenu: [
        { label: "New Session", accelerator: "CmdOrCtrl+N", click: ask("new-session") },
        { label: "New Chat", accelerator: "CmdOrCtrl+Alt+N", click: ask("new-chat") },
        { label: "New Project…", accelerator: "CmdOrCtrl+Shift+N", click: ask("new-project") },
        { label: "Open Folder…", accelerator: "CmdOrCtrl+O", click: ask("open-folder") },
        { label: "Open Quickly…", accelerator: "CmdOrCtrl+Shift+O", click: ask("open-quickly") },
        { label: "Export Conversation as Markdown", accelerator: "CmdOrCtrl+S", click: ask("save") },
        { type: "separator" },
        { label: "Close Tab", accelerator: "CmdOrCtrl+W", click: ask("close-tab") },
        { label: "Close Window", accelerator: "CmdOrCtrl+Shift+W", click: () => { if (mainWindow) mainWindow.close(); } },
        { label: "Reopen Closed Tab", accelerator: "CmdOrCtrl+Shift+T", click: ask("reopen-tab") },
      ],
    },
    {
      label: "Edit",
      submenu: [
        { role: "undo" }, { role: "redo" }, { type: "separator" },
        { role: "cut" }, { role: "copy" }, { role: "paste" }, { role: "selectAll" },
        { type: "separator" },
        { label: "Find in Conversation…", accelerator: "CmdOrCtrl+F", click: ask("find") },
      ],
    },
    {
      label: "Session",
      submenu: [
        { label: "Stop", accelerator: "CmdOrCtrl+.", click: ask("stop") },
        { type: "separator" },
        { label: "Build Mode", accelerator: "Alt+CmdOrCtrl+1", click: ask("build-mode") },
        { label: "Plan Mode", accelerator: "Alt+CmdOrCtrl+2", click: ask("plan-mode") },
      ],
    },
    {
      label: "Tools",
      submenu: [
        { label: "Show Changes", accelerator: "Alt+CmdOrCtrl+I", click: ask("changes") },
        { label: "Show Files", accelerator: "Alt+CmdOrCtrl+F", click: ask("files") },
        { label: "Run", accelerator: "CmdOrCtrl+R", click: ask("run") },
        { label: "New Terminal", accelerator: "Control+`", click: ask("terminal") },
        { type: "separator" },
        { label: "Show Panel", accelerator: "Alt+CmdOrCtrl+0", click: ask("panel") },
      ],
    },
    {
      label: "View",
      submenu: [
        { label: "Command Palette…", accelerator: "CmdOrCtrl+K", click: ask("palette") },
        { type: "separator" },
        { label: "Show Sessions", accelerator: "CmdOrCtrl+0", click: ask("sidebar") },
        { label: menuState.tabBar ? "Hide Tab Bar" : "Show Tab Bar", accelerator: "Alt+CmdOrCtrl+T", click: ask("tab-bar") },
        { label: "Show Next Tab", accelerator: "Control+Tab", click: ask("next-tab") },
        { label: "Show Previous Tab", accelerator: "Control+Shift+Tab", click: ask("previous-tab") },
        {
          label: "Show Tab",
          submenu: [
            ...[1, 2, 3, 4, 5, 6, 7, 8].map(number => ({
              label: `Tab ${number}`,
              accelerator: `CmdOrCtrl+${number}`,
              click: ask(`show-tab-${number}`),
            })),
            { label: "Last Tab", accelerator: "CmdOrCtrl+9", click: ask("show-tab-9") },
          ],
        },
        { type: "separator" },
        {
          label: "Appearance",
          submenu: [
            { label: "System", type: "radio", checked: menuState.appearance === "system", click: ask("appearance-system") },
            { label: "Light", type: "radio", checked: menuState.appearance === "light", click: ask("appearance-light") },
            { label: "Dark", type: "radio", checked: menuState.appearance === "dark", click: ask("appearance-dark") },
          ],
        },
        { type: "separator" },
        // No Reload or Reset Zoom: their default keys are the Mac's Run (⌘R) and Show
        // Sessions (⌘0), and the menu cannot hold two commands on one key.
        { role: "toggleDevTools" }, { type: "separator" },
        { role: "zoomIn" }, { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" },
      ],
    },
    { label: "Window", submenu: [{ role: "minimize" }, { role: "zoom" }] },
    {
      label: "Help",
      submenu: [
        { label: "Kuvo Code Help", click: open("https://kuvo.run/code/docs/") },
        { label: "What’s New", click: open("https://github.com/serhatandic/kuvo-code/releases") },
        { label: "Report an Issue…", click: open("https://github.com/serhatandic/kuvo-code/issues/new/choose") },
        { label: "Contact Us…", click: open("mailto:info@kuvo.run") },
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
    // A version that was found is reachable from here, whether or not Windows showed the
    // note: the tray is the one place that is always a click away.
    if (pendingUpdate) {
      items.push({
        label: installing ? `Downloading ${pendingUpdate.version}…` : `Update to ${pendingUpdate.version}…`,
        enabled: !installing,
        click: () => { void askToInstall(pendingUpdate); },
      });
    }
    if (updateState.status === 'failed') {
      items.push({ label: `Update failed: ${updateState.error ?? 'see the log'}`, enabled: false });
    }
    items.push({ label: 'Check for updates', click: () => { void checkForUpdates(); } });
    items.push({ type: 'separator' });
    items.push({ label: 'Quit', click: () => { quitting = true; app.quit(); } });
    tray.setContextMenu(Menu.buildFromTemplate(items));
  };
  rebuildTrayMenu = rebuild;
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

// Close Window (⇧⌘W on the Mac): the window goes to the tray, as its own close button
// does; the app keeps running.
ipcMain.on("kuvo:close-window", () => {
  if (mainWindow) mainWindow.close();
});

// The page's state the menu bar draws from: the tab bar's own command, and the appearance
// in use. The menu is rebuilt when either changes, so its words and checks stay true.
ipcMain.on("kuvo:menu-state", (_event, next) => {
  if (!next || typeof next !== "object") return;
  const tabBar = next.tabBar !== false;
  const appearance = ["system", "light", "dark"].includes(next.appearance) ? next.appearance : "system";
  if (tabBar === menuState.tabBar && appearance === menuState.appearance) return;
  menuState = { tabBar, appearance };
  applicationMenu();
});

// The name of the user on this machine: the Mac's own avatar in the changes' comments
// shows their initials (ChangesPanel.swift:1214-1233), and the shell is the only part that
// knows who the user is.
ipcMain.on("kuvo:user-name", (event) => {
  event.returnValue = (os.userInfo && os.userInfo().username) || "";
});

// A folder opened where the user can see it: the Mac's "Show in Finder" is the Explorer
// here (SidebarView.swift:616).
ipcMain.on("kuvo:show-in-folder", (_event, target) => {
  if (typeof target !== "string" || !target) return;
  let stats;
  try { stats = fs.statSync(target); } catch { return; }
  if (!stats.isFile() && !stats.isDirectory()) return;
  // Only reveal things inside the user's home (or an open project passed by the harness).
  const home = os.homedir();
  const resolved = path.resolve(target);
  if (resolved !== home && !resolved.startsWith(home + path.sep)) return;
  shell.openPath(resolved);
});

// The page asks the bridge what only the shell knows (preload.js): the terminal's port.
ipcMain.on("kuvo:terminal-port", (event) => {
  event.returnValue = terminalPort;
});

// A settings page asks for something outside the app — a system page, a doc, a folder.
ipcMain.on("kuvo:open-external", (_event, url) => {
  if (typeof url !== "string" || !url) return;
  let parsed;
  try { parsed = new URL(url); } catch { return; }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return;
  void shell.openExternal(parsed.toString());
});

// A machine reached over SSH: is it there, and can we talk to it?
ipcMain.handle("kuvo:ssh-check", async (_event, destination) => checkDestination(destination));

function shutdown() {
  if (terminalServer) { try { void terminalServer.close(); } catch {} terminalServer = null; }
  if (harness) { try { harness.kill(); } catch {} harness = null; }
}

// ---- The updates ----
//
// Our releases are prereleases with a tag of their own, and electron-updater's GitHub
// provider looks for another kind of release — so the shell asks GitHub itself, compares the
// versions, and offers the installer. The keys are ours: the installer is the portable one's
// bigger brother, and it replaces what is installed.
//
// The check goes through Electron's network stack, not Node's: it reads this machine's proxy
// and its certificate store, so a machine whose browser reaches GitHub reaches it here too.
// When the API is limited or blocked, the releases feed answers instead.

/// What the updater is doing, for the page and the tray: the version that is running, the one
/// waiting to be installed, and how the last attempt ended.
const updateState = { status: 'idle', error: null, checkedAt: null, downloaded: null };
let pendingUpdate = null;
let updateCheck = null;
let installing = false;

const updateStatus = () => ({
  version: app.getVersion(),
  available: pendingUpdate?.version ?? null,
  notes: pendingUpdate?.notes ?? '',
  status: updateState.status,
  error: updateState.error,
  checkedAt: updateState.checkedAt,
  logPath: updateLogPath,
});

function refreshUpdateMenus() {
  try { applicationMenu(); } catch {}
  try { rebuildTrayMenu?.(); } catch {}
}

async function releasesFromApi() {
  const response = await net.fetch(RELEASES_API, {
    headers: { 'user-agent': 'Kuvo-Code', accept: 'application/vnd.github+json' },
  });
  if (!response.ok) {
    const left = response.headers.get('x-ratelimit-remaining');
    throw new Error(`GitHub answered ${response.status}${left === '0' ? ' (its limit for this network is used up)' : ''}`);
  }
  return response.json();
}

async function releasesFromFeed() {
  const response = await net.fetch(RELEASES_ATOM, { headers: { 'user-agent': 'Kuvo-Code' } });
  if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
  return parseAtom(await response.text());
}

/// One check at a time: the menu, the tray, the startup note and the page can all ask.
function checkForUpdates({ quiet = false, notify = quiet } = {}) {
  if (updateCheck) return updateCheck;
  updateCheck = runUpdateCheck({ quiet, notify }).finally(() => { updateCheck = null; });
  return updateCheck;
}

async function runUpdateCheck({ quiet, notify }) {
  updateState.status = 'checking';
  updateState.error = null;
  refreshUpdateMenus();
  let releases;
  try {
    releases = await releasesFromApi();
    logUpdate('checked the releases (the API)');
  } catch (error) {
    logUpdate(`the API failed: ${messageOf(error)}`);
    try {
      releases = await releasesFromFeed();
      logUpdate('checked the releases (the feed)');
    } catch (second) {
      logUpdate(`the feed failed too: ${messageOf(second)}`);
      updateState.status = 'failed';
      updateState.error = describeError(second);
      refreshUpdateMenus();
      if (!quiet) {
        dialog.showErrorBox('Kuvo Code', `Kuvo Code couldn't check for updates.\n\n${updateState.error}\n\nThe log is at ${updateLogPath}.`);
      }
      return null;
    }
  }

  const update = pickRelease(releases, app.getVersion());
  updateState.checkedAt = new Date().toISOString();
  if (!update) {
    pendingUpdate = null;
    updateState.status = 'current';
    logUpdate(`${app.getVersion()} is the latest`);
    refreshUpdateMenus();
    if (!quiet) {
      const message = { type: 'info', title: 'Kuvo Code', message: `Kuvo Code ${app.getVersion()} is the latest.` };
      if (mainWindow) dialog.showMessageBox(mainWindow, message);
      else dialog.showMessageBox(message);
    }
    return null;
  }

  pendingUpdate = update;
  updateState.status = 'available';
  logUpdate(`${update.version} is available`);
  refreshUpdateMenus();
  if (notify) {
    // On startup, a note in the corner — not a question that waits for an answer. Clicking
    // it asks the question.
    try {
      const note = new Notification({ title: 'Kuvo Code', body: `Version ${update.version} is available.` });
      note.on('click', () => { void askToInstall(update); });
      note.show();
    } catch (error) {
      logUpdate(`a notification failed: ${messageOf(error)}`);
    }
  }
  if (!quiet) await askToInstall(update);
  return update;
}

async function askToInstall(update) {
  if (!update || installing) return;
  const question = {
    type: 'info', buttons: ['Download and install', 'Later'], defaultId: 0, cancelId: 1,
    title: 'A new version',
    message: `Kuvo Code ${update.version} is available. Download it now?`,
    detail: `This is Kuvo Code ${app.getVersion()}. The installer downloads first, then opens.`,
  };
  if (mainWindow && !mainWindow.isVisible()) mainWindow.show();
  const parent = mainWindow && !mainWindow.isDestroyed() ? mainWindow : null;
  const choice = parent ? await dialog.showMessageBox(parent, question) : await dialog.showMessageBox(question);
  if (choice.response !== 0) return;
  await installUpdate(update);
}

async function installUpdate(update) {
  if (!update || installing) return;
  installing = true;
  updateState.status = 'downloading';
  updateState.error = null;
  refreshUpdateMenus();
  let lastReport = 0;
  const showProgress = (written, total) => {
    const now = Date.now();
    if (now - lastReport < 150 && written !== total) return;
    lastReport = now;
    const fraction = total ? Math.min(1, written / total) : -1;
    try { if (mainWindow) mainWindow.setProgressBar(fraction); } catch {}
    try {
      if (tray) tray.setToolTip(total && fraction >= 0
        ? `Kuvo Code — downloading ${update.version}: ${Math.round(fraction * 100)}%`
        : `Kuvo Code — downloading ${update.version}`);
    } catch {}
  };
  try {
    logUpdate(`downloading ${update.name}`);
    if (mainWindow && !mainWindow.isVisible()) mainWindow.show();
    const file = await downloadInstaller({
      url: update.url,
      name: update.name,
      directory: updatesFolder,
      fetch: (url, init) => net.fetch(url, init),
      onProgress: showProgress,
    });
    updateState.downloaded = file;
    logUpdate(`downloaded ${path.basename(file)}`);
    try { if (mainWindow) mainWindow.setProgressBar(-1); } catch {}
    try { if (tray) tray.setToolTip('Kuvo Code'); } catch {}
    updateState.status = 'installing';
    refreshUpdateMenus();
    await startInstaller(file);
    logUpdate('the installer started; quitting so it can replace the files');
    quitting = true;
    // A moment for the installer's own window to come up before this one goes.
    setTimeout(() => app.quit(), 600);
  } catch (error) {
    updateState.status = 'failed';
    updateState.error = describeError(error);
    logUpdate(`failed: ${messageOf(error)}`);
    try { if (mainWindow) mainWindow.setProgressBar(-1); } catch {}
    try { if (tray) tray.setToolTip('Kuvo Code'); } catch {}
    refreshUpdateMenus();
    dialog.showErrorBox(
      'Kuvo Code',
      `Kuvo Code couldn't install ${update.version}.\n\n${updateState.error}\n\nThe log is at ${updateLogPath}.`,
    );
  } finally {
    installing = false;
  }
}

/// Start the installer itself; if Windows refuses the direct start, ask it to open the file,
/// which is what a double-click does. Its own error is the one worth reporting.
async function startInstaller(file) {
  try {
    await launchInstaller({ path: file });
  } catch (error) {
    logUpdate(`starting it directly failed (${messageOf(error)}); asking Windows to open it`);
    const failure = await shell.openPath(file);
    if (failure) throw new Error(failure);
  }
}

ipcMain.handle('kuvo:update-status', () => updateStatus());
ipcMain.handle('kuvo:update-check', async () => {
  // From the page, the page shows the answer: no dialog, and no note it did not ask for.
  await checkForUpdates({ quiet: true, notify: false });
  return updateStatus();
});
ipcMain.handle('kuvo:update-install', async () => {
  if (!pendingUpdate) return updateStatus();
  await installUpdate(pendingUpdate);
  return updateStatus();
});

app.whenReady().then(async () => {
  try {
    const cfg = loadConfig();
    if (cfg.autoStart) app.setLoginItemSettings({ openAtLogin: true });
    applyShellPreferences();
    globalShortcut.register('CommandOrControl+Shift+K', toggleWindow);
    applicationMenu();
    // Installers an earlier attempt left behind are a hundred megabytes each; a day is
    // long enough to retry a failed one by hand.
    void sweepInstallers(updatesFolder).then(removed => {
      if (removed.length) logUpdate(`removed ${removed.length} old installer${removed.length === 1 ? '' : 's'}`);
    });
    // Auto-update on startup, unless the user turned it off: a note, not a question. The
    // smoke test only checks that the shell starts, so it does not go looking for a version.
    const smoking = process.argv.includes('--smoke');
    if (cfg.autoUpdate !== false && !smoking) void checkForUpdates({ quiet: true });
    // And again a few times a day, so a version published while the app is open is still
    // found — the Mac app's updater checks in the background too. The timer stays, and
    // reads the setting each time, so turning updates on in Settings starts the checks
    // without a restart.
    setInterval(() => {
      if (loadConfig().autoUpdate !== false) void checkForUpdates({ quiet: true });
    }, 6 * 60 * 60 * 1000);
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

