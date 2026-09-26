// Rip It Out desktop app (Electron).
//
// Starts the Python server (bundled in the packaged app, the project's .venv
// during development) on a local port and shows the web UI in its own window.

const { app, BrowserWindow, Menu, dialog, ipcMain, session, shell, systemPreferences } = require("electron");
const { spawn, spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const path = require("node:path");
const updates = require("./updates");

const APP_NAME = "Rip It Out";
const PREFERRED_PORT = Number(process.env.RIPITOUT_PORT) || 38765; // stable, so the UI keeps its saved preferences
const ROOT = path.resolve(__dirname, "..");
const PACKAGED = app.isPackaged;
const WINDOWS = process.platform === "win32";
const PYTHON = PACKAGED
  ? path.join(process.resourcesPath, "python", ...(WINDOWS ? ["python.exe"] : ["bin", "python3"]))
  : path.join(ROOT, ".venv", ...(WINDOWS ? ["Scripts", "python.exe"] : ["bin", "python"]));
const BIN = PACKAGED ? path.join(process.resourcesPath, "bin") : null;
const USER_DATA = app.getPath("userData"); // ~/Library/Application Support/Rip It Out, %APPDATA%\Rip It Out
const CONFIG = process.env.STEMTOOL_CONFIG || path.join(USER_DATA, "settings.json"); // shared with the server: library folder
const STATE = path.join(USER_DATA, "desktop.json"); // this file's own state
// A yt-dlp update the user chose to install goes here, never into the app bundle.
const OVERLAY = path.join(USER_DATA, "site-packages");
const LOGS = app.getPath("logs"); // ~/Library/Logs/Rip It Out
const YTDLP_PACKAGES = ["yt-dlp", "yt-dlp-ejs"]; // the rest (requests, certifi, ...) comes with the app
const UPDATE_DIR = path.join(USER_DATA, "update"); // downloaded DMG and the unpacked new app
// Windows can't send the server a signal, so it is asked to quit over HTTP with this.
const SHUTDOWN_TOKEN = crypto.randomBytes(24).toString("hex");

let win = null;
let server = null;
let port = null;
let quitting = false;

// --- small helpers ---------------------------------------------------------------

const origin = () => `http://localhost:${port}`;

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return {}; }
}
function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function getJson(urlPath, timeout = 1500) {
  return new Promise((resolve) => {
    const req = http.get(`http://127.0.0.1:${port}${urlPath}`, { timeout }, (res) => {
      let body = "";
      res.on("data", (c) => { body += c; });
      res.on("end", () => { try { resolve(JSON.parse(body)); } catch { resolve(null); } });
    });
    req.on("error", () => resolve(null));
    req.on("timeout", () => { req.destroy(); resolve(null); });
  });
}

function portFree(p) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once("error", () => resolve(false));
    srv.once("listening", () => srv.close(() => resolve(true)));
    srv.listen(p, "127.0.0.1");
  });
}

async function pickPort() {
  for (let p = PREFERRED_PORT; p < PREFERRED_PORT + 20; p++) if (await portFree(p)) return p;
  throw new Error(`No free port between ${PREFERRED_PORT} and ${PREFERRED_PORT + 19}`);
}

// --- the Python server ---------------------------------------------------------------

function startServer() {
  fs.mkdirSync(LOGS, { recursive: true });
  const logFile = path.join(LOGS, "server.log");
  try { if (fs.statSync(logFile).size > 5e6) fs.renameSync(logFile, path.join(LOGS, "server.old.log")); } catch {}
  const log = fs.openSync(logFile, "a");
  fs.writeSync(log, `\n=== ${new Date().toISOString()} ${APP_NAME} ${app.getVersion()} on port ${port}\n`);

  const env = { ...process.env, STEMTOOL_CONFIG: CONFIG, STEMTOOL_SHUTDOWN_TOKEN: SHUTDOWN_TOKEN,
    PYTHONUNBUFFERED: "1", PYTHONNOUSERSITE: "1", PYTHONUTF8: "1" };
  if (PACKAGED) {
    if (WINDOWS) {
      const system = process.env.SystemRoot || "C:\\Windows";
      for (const key of Object.keys(env)) if (key.toUpperCase() === "PATH") delete env[key]; // it's "Path" there
      env.PATH = [BIN, path.join(system, "System32"), system].join(path.delimiter);
    } else {
      env.PATH = `${BIN}:/usr/bin:/bin:/usr/sbin:/sbin`;
    }
    if (overlayActive()) env.PYTHONPATH = OVERLAY;
    // Python's bytecode cache goes here, not into the app: writing into the bundle breaks its code seal.
    // (The Windows build ships it compiled, in a folder the installer replaces whole.)
    if (!WINDOWS) env.PYTHONPYCACHEPREFIX = path.join(USER_DATA, "pycache");
    delete env.PYTHONHOME;
  }
  server = spawn(PYTHON, ["-m", "uvicorn", "stemtool.server:app", "--host", "127.0.0.1", "--port", String(port)], {
    cwd: PACKAGED ? USER_DATA : ROOT, env, stdio: ["ignore", log, log], windowsHide: true,
  });
  const proc = server;
  proc.on("exit", (code, signal) => {
    if (server === proc) server = null;
    if (!quitting) showProblem(`The engine stopped (${signal || `exit code ${code}`}).`);
  });
  proc.on("error", (err) => showProblem(`Couldn't start the engine: ${err.message}`));
}

async function waitForServer(timeoutMs = 120000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (!server) return false;
    if (await getJson("/api/status")) return true;
    await new Promise((r) => setTimeout(r, 300));
  }
  return false;
}

function stopServer() {
  const proc = server;
  server = null;
  if (!proc || proc.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    const force = setTimeout(() => killTree(proc), 15000);
    proc.once("exit", () => { clearTimeout(force); resolve(); });
    // uvicorn shuts down cleanly and ends running jobs
    if (WINDOWS) askServerToQuit().then((ok) => { if (!ok) killTree(proc); });
    else proc.kill("SIGTERM");
  });
}

function askServerToQuit() {
  return new Promise((resolve) => {
    const req = http.request(`http://127.0.0.1:${port}/api/shutdown`,
      { method: "POST", headers: { "X-Shutdown-Token": SHUTDOWN_TOKEN }, timeout: 3000 },
      (res) => { res.resume(); resolve(res.statusCode === 200); });
    req.on("error", () => resolve(false));
    req.on("timeout", () => { req.destroy(); resolve(false); });
    req.end();
  });
}

// The server and the processing it started. On Windows, ending a process leaves its children running.
function killTree(proc) {
  if (proc.exitCode !== null) return;
  if (WINDOWS) spawnSync("taskkill", ["/pid", String(proc.pid), "/T", "/F"], { windowsHide: true });
  else { try { proc.kill("SIGKILL"); } catch {} }
}

async function serverBusy() {
  const jobs = await getJson("/api/jobs");
  return Array.isArray(jobs) && jobs.some((j) => j.status === "queued" || j.status === "running");
}

// --- window ------------------------------------------------------------------------------

function splash(message, detail = "", error = false) {
  if (!win) return;
  const q = new URLSearchParams({ message, detail, error: error ? "1" : "" });
  win.loadFile(path.join(__dirname, "splash.html"), { search: q.toString() });
}

function showProblem(message) {
  splash(message, `The log is in ${path.join(LOGS, "server.log")}. Use Restart Engine in the Library menu to try again.`, true);
}

function createWindow() {
  win = new BrowserWindow({
    width: 1320, height: 900, minWidth: 720, minHeight: 560,
    title: APP_NAME, backgroundColor: "#070b10", show: false,
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, sandbox: true },
  });
  win.once("ready-to-show", () => win.show());
  win.on("closed", () => { win = null; });

  // Links to other sites (YouTube sources, GitHub) open in the normal browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  win.webContents.on("will-navigate", (e, url) => {
    if (port && url.startsWith(origin())) return;
    if (url.startsWith("file:")) return;
    e.preventDefault();
    if (/^https?:/.test(url)) shell.openExternal(url);
  });
}

async function boot() {
  splash("Starting the engine…", "The first start after installing takes a little longer.");
  try {
    port = await pickPort();
  } catch (err) { showProblem(err.message); return; }
  startServer();
  if (await waitForServer()) {
    if (win) win.loadURL(`${origin()}/`);
  } else if (server) {
    showProblem("The engine didn't start in time.");
  }
}

async function restartEngine() {
  if (await serverBusy() && !confirmStop("Restart the engine?")) return;
  quitting = true; // not a crash, don't show the error page
  await stopServer();
  quitting = false;
  boot();
}

function confirmStop(message) {
  const choice = dialog.showMessageBoxSync(win, {
    type: "warning", buttons: ["Continue", "Cancel"], defaultId: 1, cancelId: 1,
    message, detail: "Songs are still being processed. This stops them, and waiting songs are forgotten.",
  });
  return choice === 0;
}

// --- permissions: microphone and camera for the Record tab ---------------------------------

function setupPermissions() {
  const ours = (url) => !!port && typeof url === "string" && url.startsWith(origin());
  session.defaultSession.setPermissionCheckHandler((_wc, permission, requestingOrigin) =>
    ours(requestingOrigin) && ["media", "speaker-selection", "clipboard-sanitized-write"].includes(permission));
  session.defaultSession.setPermissionRequestHandler(async (_wc, permission, callback, details) => {
    if (!ours(details.requestingUrl)) return callback(false);
    if (permission !== "media") return callback(["speaker-selection", "clipboard-sanitized-write", "fullscreen"].includes(permission));
    let ok = true;
    if (process.platform === "darwin") { // macOS asks once per app, then remembers
      const types = details.mediaTypes || [];
      if (types.includes("audio")) ok = ok && await systemPreferences.askForMediaAccess("microphone");
      if (types.includes("video")) ok = ok && await systemPreferences.askForMediaAccess("camera");
    }
    callback(ok);
  });
}

// --- yt-dlp updates ------------------------------------------------------------------------
//
// Each release bundles a pinned yt-dlp version it was tested with. Nothing updates on
// its own. When YouTube breaks downloads before the next release, the user can choose
// to install the newest yt-dlp from PyPI into OVERLAY (wheels only, so no install
// scripts run), and go back to the bundled version at any time.

function overlayActive() {
  const state = readJson(STATE);
  // An update made under another app version is dropped: the new release's tested
  // yt-dlp takes over again.
  if (state.ytdlpOverlayVersion && state.ytdlpOverlayVersion !== app.getVersion()) {
    fs.rmSync(OVERLAY, { recursive: true, force: true });
    writeJson(STATE, { ...state, ytdlpOverlayVersion: null });
    return false;
  }
  return !!state.ytdlpOverlayVersion && fs.existsSync(OVERLAY);
}

async function updateYtDlp() {
  if (!PACKAGED) {
    dialog.showMessageBox(win, { message: "In development, update yt-dlp in the .venv with pip." });
    return;
  }
  const { response } = await dialog.showMessageBox(win, {
    type: "question", buttons: ["Update", "Cancel"], defaultId: 0, cancelId: 1,
    message: "Install the newest YouTube downloader?",
    detail: "This downloads the latest yt-dlp release from PyPI (pypi.org). It hasn't been tested with this version " +
      "of Rip It Out. Use it when downloads stop working. Library > Reset YouTube Downloader goes back to the bundled version.",
  });
  if (response !== 0) return;
  const tmp = `${OVERLAY}.new`;
  fs.rmSync(tmp, { recursive: true, force: true });
  const pip = spawn(PYTHON, ["-m", "pip", "install", "--target", tmp, "--only-binary", ":all:", "--no-deps",
    "--disable-pip-version-check", "--no-input", ...YTDLP_PACKAGES],
  { env: { ...process.env, PYTHONNOUSERSITE: "1" }, windowsHide: true });
  let output = "";
  pip.stdout.on("data", (d) => { output += d; });
  pip.stderr.on("data", (d) => { output += d; });
  pip.on("exit", async (code) => {
    fs.appendFileSync(path.join(LOGS, "server.log"), `\n=== yt-dlp update (exit ${code})\n${output.slice(-4000)}\n`);
    if (code !== 0) {
      fs.rmSync(tmp, { recursive: true, force: true });
      dialog.showMessageBox(win, { type: "error", message: "Updating the YouTube downloader failed",
        detail: "Details are in the log (Library menu, Show Log)." });
      return;
    }
    fs.rmSync(OVERLAY, { recursive: true, force: true });
    fs.renameSync(tmp, OVERLAY);
    writeJson(STATE, { ...readJson(STATE), ytdlpOverlayVersion: app.getVersion() });
    const restart = await dialog.showMessageBox(win, {
      type: "info", buttons: ["Restart Engine", "Later"], defaultId: 0, cancelId: 1,
      message: "YouTube downloader updated", detail: "It is used after the engine restarts.",
    });
    if (restart.response === 0) restartEngine();
  });
}

async function resetYtDlp() {
  if (!fs.existsSync(OVERLAY)) {
    dialog.showMessageBox(win, { message: "Already using the bundled YouTube downloader." });
    return;
  }
  fs.rmSync(OVERLAY, { recursive: true, force: true });
  writeJson(STATE, { ...readJson(STATE), ytdlpOverlayVersion: null });
  restartEngine();
}

// --- app updates (see updates.js) --------------------------------------------------------------

const updateState = { update: null, staged: null, abort: null };

// Errors go back as { error } so the page can show them as they are.
const handle = (channel, fn) => ipcMain.handle(channel, async (e, ...args) => {
  try { return await fn(e, ...args); } catch (err) { return { error: err.name === "AbortError" ? "Cancelled." : err.message }; }
});

function updateBlocker() {
  if (!PACKAGED) return "In development, update with git pull.";
  if (WINDOWS) return "On Windows, get the new installer from the release page.";
  return updates.installProblem(updates.bundlePath(app.getPath("exe")));
}

function setupUpdates() {
  fs.rmSync(UPDATE_DIR, { recursive: true, force: true }); // leftovers from an earlier update

  handle("update-check", async () => {
    const result = await updates.check({ currentVersion: app.getVersion(), releasesUrl: process.env.RIPITOUT_UPDATE_URL });
    updateState.update = result.update;
    return { ...result, blocker: result.update ? updateBlocker() : null, ready: !!updateState.staged };
  });

  handle("update-download", async (e) => {
    const u = updateState.update;
    if (!u) throw new Error("Check for updates first.");
    const blocker = updateBlocker();
    if (blocker) throw new Error(blocker);
    if (updateState.abort) throw new Error("A download is already running.");
    fs.rmSync(UPDATE_DIR, { recursive: true, force: true });
    updateState.abort = new AbortController();
    try {
      const dmg = await updates.download(u, UPDATE_DIR, {
        signal: updateState.abort.signal, userAgent: `RipItOut/${app.getVersion()}`,
        onProgress: (got, total) => { if (!e.sender.isDestroyed()) e.sender.send("update-progress", { got, total }); },
      });
      if (!e.sender.isDestroyed()) e.sender.send("update-progress", { got: u.size, total: u.size, unpacking: true });
      updateState.staged = await updates.extractApp(dmg, UPDATE_DIR, u.version);
      return { ready: true, version: u.version };
    } catch (err) {
      fs.rmSync(UPDATE_DIR, { recursive: true, force: true });
      throw err;
    } finally {
      updateState.abort = null;
    }
  });

  handle("update-cancel", () => { updateState.abort?.abort(); return { ok: true }; });

  handle("update-install", async () => {
    if (!updateState.staged) throw new Error("Nothing to install yet.");
    if (await serverBusy() && !confirmStop("Restart to update?")) return { cancelled: true };
    const script = updates.writeSwapScript(UPDATE_DIR);
    fs.mkdirSync(LOGS, { recursive: true });
    const log = fs.openSync(path.join(LOGS, "update.log"), "a");
    const target = updates.bundlePath(app.getPath("exe"));
    spawn("/bin/bash", [script, String(process.pid), updateState.staged, target],
      { detached: true, stdio: ["ignore", log, log] }).unref();
    quitting = true;
    await stopServer();
    app.quit();
    return { ok: true };
  });
}

function checkForUpdatesFromMenu() {
  if (win && port) win.webContents.executeJavaScript("showTab('settings'); checkForUpdates()");
}

// --- menu ------------------------------------------------------------------------------------

async function libraryPath() {
  const s = await getJson("/api/status");
  return s ? s.library_dir : null;
}

function buildMenu() {
  const isMac = process.platform === "darwin";
  const template = [
    ...(isMac ? [{
      label: APP_NAME,
      submenu: [
        { role: "about" },
        { label: "Check for Updates…", click: checkForUpdatesFromMenu },
        { type: "separator" }, { role: "services" }, { type: "separator" },
        { role: "hide" }, { role: "hideOthers" }, { role: "unhide" }, { type: "separator" }, { role: "quit" },
      ],
    }] : []),
    { role: "editMenu" }, // copy and paste in text fields
    {
      label: "Library",
      submenu: [
        { label: isMac ? "Show Library in Finder" : "Show Library in Explorer", click: async () => { const p = await libraryPath(); if (p) shell.openPath(p); } },
        { label: "Change Library Folder…", click: () => win && win.webContents.executeJavaScript("showTab('settings')") },
        { type: "separator" },
        { label: "Update YouTube Downloader…", click: updateYtDlp },
        { label: "Reset YouTube Downloader", click: resetYtDlp },
        { label: "Restart Engine", click: restartEngine },
        { label: "Show Log", click: () => shell.openPath(path.join(LOGS, "server.log")) },
      ],
    },
    {
      label: "View",
      submenu: [
        { role: "reload" }, { role: "toggleDevTools" }, { type: "separator" },
        { role: "resetZoom" }, { role: "zoomIn" }, { role: "zoomOut" }, { type: "separator" }, { role: "togglefullscreen" },
      ],
    },
    { role: "windowMenu" },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// --- app lifecycle ---------------------------------------------------------------------------

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
  });

  ipcMain.handle("choose-folder", async (_e, current) => {
    const result = await dialog.showOpenDialog(win, {
      title: "Choose your library folder", buttonLabel: "Use as Library",
      defaultPath: current || app.getPath("music"), properties: ["openDirectory", "createDirectory"],
    });
    return result.canceled ? null : result.filePaths[0];
  });

  app.whenReady().then(() => {
    buildMenu();
    setupPermissions();
    setupUpdates();
    createWindow();
    boot();
  });

  app.on("activate", () => {
    if (!win) { createWindow(); if (port && server) win.loadURL(`${origin()}/`); else boot(); }
  });

  // One window, one app: closing the window quits.
  app.on("window-all-closed", () => app.quit());

  app.on("before-quit", (e) => {
    if (quitting) return;
    e.preventDefault();
    (async () => {
      if (await serverBusy() && !confirmStop("Quit Rip It Out?")) return;
      quitting = true;
      await stopServer();
      app.quit();
    })();
  });
}
