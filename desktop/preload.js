// The only bridge between the web UI and the desktop app: a native folder picker and
// app updates.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("ripitout", {
  chooseFolder: (current) => ipcRenderer.invoke("choose-folder", current || ""),
  updates: {
    check: () => ipcRenderer.invoke("update-check"),
    download: () => ipcRenderer.invoke("update-download"),
    cancel: () => ipcRenderer.invoke("update-cancel"),
    install: () => ipcRenderer.invoke("update-install"),
    onProgress: (fn) => { ipcRenderer.on("update-progress", (_e, p) => fn(p)); },
  },
});
