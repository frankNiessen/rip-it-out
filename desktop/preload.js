// The only bridge between the web UI and the desktop app: a native folder picker.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("ripitout", {
  chooseFolder: (current) => ipcRenderer.invoke("choose-folder", current || ""),
});
