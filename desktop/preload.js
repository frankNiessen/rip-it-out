// The only bridge between the web UI and the desktop app: a native folder picker, app
// updates, and the system's microphone and camera access.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("ripitout", {
  chooseFolder: (current) => ipcRenderer.invoke("choose-folder", current || ""),
  media: {
    access: () => ipcRenderer.invoke("media-access"),
    openSettings: (kind) => ipcRenderer.invoke("open-privacy-settings", kind),
  },
  updates: {
    check: () => ipcRenderer.invoke("update-check"),
    download: () => ipcRenderer.invoke("update-download"),
    cancel: () => ipcRenderer.invoke("update-cancel"),
    install: () => ipcRenderer.invoke("update-install"),
    onProgress: (fn) => { ipcRenderer.on("update-progress", (_e, p) => fn(p)); },
  },
});
