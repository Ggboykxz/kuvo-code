// What the page may ask of the shell it lives in: the platform it is on, and the window's
// own motions (the Mac's double-click on the title bar zooms; on Windows, that is the
// window maximised).
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("kuvo", {
  platform: "windows",
  // The window is the shell's: the page knows it by the bridge, not by the address it was
  // opened at, so a reload — or a stray Back — cannot take the title bar's room for the
  // window's controls, or the terminal's port, away from it.
  isShell: true,
  terminalPort: ipcRenderer.sendSync("kuvo:terminal-port"),
  // The name of the user on this machine, for the avatar the Mac draws beside a comment
  // (ChangesPanel.swift:1214-1233).
  userName: ipcRenderer.sendSync("kuvo:user-name"),
  maximize: () => ipcRenderer.send("kuvo:maximize"),
  // The menu bar's items that act on the conversation.
  onMenu: (callback) => ipcRenderer.on("kuvo:menu", (_event, id) => callback(id)),
  // The project the app switched to: the shell remembers it, so the app opens here next
  // time (Workspace.projects, and the Mac's own list of folders).
  rememberProject: (folder) => ipcRenderer.send("kuvo:remember-project", folder),
  // A folder opened where the user can see it: the Mac's "Show in Finder" is the
  // Explorer here (SidebarView.swift:616).
  showInFolder: (path) => ipcRenderer.send("kuvo:show-in-folder", path),
});
