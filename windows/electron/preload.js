// What the page may ask of the shell it lives in: the platform it is on, and the window's
// own motions (the Mac's double-click on the title bar zooms; on Windows, that is the
// window maximised).
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("kuvo", {
  platform: "windows",
  maximize: () => ipcRenderer.send("kuvo:maximize"),
  // The menu bar's items that act on the conversation.
  onMenu: (callback) => ipcRenderer.on("kuvo:menu", (_event, id) => callback(id)),
});
