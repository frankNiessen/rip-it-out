// App updates from GitHub releases, only when the user asks.
//
// Each release carries the DMG and RipItOut-<version>.update.json: version, DMG name,
// size and SHA-256, signed with the project's ed25519 key (macos/sign_update.mjs; the
// private key is a repository secret). The app checks that signature with the public
// key below, downloads the DMG, compares size and hash, copies the app out of it and,
// after the app has quit, a small script swaps the bundle and starts the new version.
// If anything doesn't match, nothing is installed.
//
// Plain Node on purpose (no Electron imports), so it can be tested on its own.

const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { Readable, Transform } = require("node:stream");
const { pipeline } = require("node:stream/promises");

const RELEASES = "https://api.github.com/repos/frankNiessen/rip-it-out/releases/latest";
const APP_NAME = "Rip It Out";
const PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEALJ6YT+/oNcgvuommOTojjpIq2ix4jSGwHOQ2WgI3YJQ=
-----END PUBLIC KEY-----`;

function compareVersions(a, b) {
  const pa = String(a).replace(/^v/, "").split(".").map(Number);
  const pb = String(b).replace(/^v/, "").split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return Math.sign(d);
  }
  return 0;
}

// What the signature covers. Changing this breaks updates from older versions.
function signedMessage(m) {
  return `ripitout-update\n${m.version}\n${m.file}\n${m.size}\n${m.sha256}`;
}

function verifyManifest(doc, publicKey = PUBLIC_KEY) {
  const m = doc && doc.manifest;
  const ok = m && /^\d+\.\d+\.\d+$/.test(m.version) && /^[\w.-]+\.dmg$/.test(m.file)
    && Number.isSafeInteger(m.size) && m.size > 0 && /^[0-9a-f]{64}$/.test(m.sha256)
    && typeof doc.signature === "string"
    && crypto.verify(null, Buffer.from(signedMessage(m)), publicKey, Buffer.from(doc.signature, "base64"));
  if (!ok) throw new Error("The update's signature doesn't match. Nothing was downloaded.");
  return m;
}

async function getJson(url, userAgent) {
  const res = await fetch(url, { headers: { "User-Agent": userAgent, Accept: "application/json" } });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  return res.json();
}

// The latest release, and whether it can be installed from within the app.
async function check({ currentVersion, releasesUrl = RELEASES, publicKey = PUBLIC_KEY }) {
  const userAgent = `RipItOut/${currentVersion}`;
  let release;
  try { release = await getJson(releasesUrl, userAgent); } catch (err) {
    throw new Error(`Couldn't reach GitHub (${err.message}).`);
  }
  const version = String(release.tag_name || "").replace(/^v/, "");
  const result = { current: currentVersion, version, newer: compareVersions(version, currentVersion) > 0,
    notesUrl: release.html_url, update: null };
  if (!result.newer) return result;
  const assets = release.assets || [];
  const info = assets.find((a) => a.name === `RipItOut-${version}.update.json`);
  if (!info) return result; // an older style release: download it from the release page
  const m = verifyManifest(await getJson(info.browser_download_url, userAgent), publicKey);
  const dmg = assets.find((a) => a.name === m.file);
  if (m.version !== version || !dmg) throw new Error("The release's update files don't fit together.");
  result.update = { ...m, url: dmg.browser_download_url };
  return result;
}

// Downloads the DMG into dir and checks size and hash. Returns its path.
async function download(update, dir, { signal, onProgress, userAgent = "RipItOut" } = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, update.file);
  const part = `${file}.part`;
  const res = await fetch(update.url, { signal, headers: { "User-Agent": userAgent } });
  if (!res.ok || !res.body) throw new Error(`Download failed (${res.status})`);
  const hash = crypto.createHash("sha256");
  let got = 0, last = 0;
  const count = new Transform({
    transform(chunk, _enc, done) {
      got += chunk.length;
      hash.update(chunk);
      if (got > update.size) return done(new Error("The download is larger than announced."));
      const now = Date.now();
      if (onProgress && (now - last > 200 || got === update.size)) { last = now; onProgress(got, update.size); }
      done(null, chunk);
    },
  });
  try {
    await pipeline(Readable.fromWeb(res.body), count, fs.createWriteStream(part), { signal });
    if (got !== update.size || hash.digest("hex") !== update.sha256) {
      throw new Error("The download doesn't match the signed release. Nothing was installed.");
    }
    fs.renameSync(part, file);
    return file;
  } finally {
    fs.rmSync(part, { force: true });
  }
}

function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`${path.basename(cmd)} failed: ${(r.stderr || r.error?.message || "").trim().slice(-300)}`);
  return r.stdout.trim();
}

// Copies the app out of the DMG into dir and checks its version and code seal.
function extractApp(dmg, dir, version) {
  const mount = fs.mkdtempSync(path.join(dir, "mnt-"));
  const staged = path.join(dir, `${APP_NAME}.app`);
  fs.rmSync(staged, { recursive: true, force: true });
  run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg]);
  try {
    run("/usr/bin/ditto", [path.join(mount, `${APP_NAME}.app`), staged]);
  } finally {
    spawnSync("/usr/bin/hdiutil", ["detach", mount, "-force"]);
    fs.rmSync(mount, { recursive: true, force: true });
  }
  const plist = path.join(staged, "Contents", "Info.plist");
  const got = run("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", plist]);
  if (got !== version) throw new Error(`The downloaded app is version ${got}, not ${version}.`);
  run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged]);
  fs.rmSync(dmg, { force: true });
  return staged;
}

// The .app folder the running executable belongs to.
function bundlePath(exe) {
  return path.resolve(exe, "..", "..", "..");
}

// Why the app can't replace itself where it is, or null if it can.
function installProblem(bundle) {
  if (!bundle.endsWith(".app")) return "Updates work in the packaged app only.";
  if (bundle.includes("/AppTranslocation/") || bundle.startsWith("/Volumes/")) {
    return `Move ${APP_NAME} into the Applications folder first, start it from there, then update.`;
  }
  try { fs.accessSync(path.dirname(bundle), fs.constants.W_OK); } catch {
    return `Your user can't write to ${path.dirname(bundle)}. Download the new version from GitHub instead.`;
  }
  return null;
}

// Waits for the app to quit, puts the new bundle in place (the old one comes back if
// that fails) and starts it. Tests set RIPITOUT_OPEN so nothing is launched.
const SWAP_SCRIPT = `#!/bin/bash
PID="$1"; NEW="$2"; TARGET="$3"
echo "=== update $(date) : $NEW -> $TARGET"
for _ in $(seq 1 240); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
OLD="$TARGET.old-$$"
if ! mv "$TARGET" "$OLD"; then echo "could not move the old app"; \${RIPITOUT_OPEN:-open} "$TARGET"; exit 1; fi
if mv "$NEW" "$TARGET"; then
  rm -rf "$OLD"; echo "installed"
else
  echo "could not move the new app, restoring"; rm -rf "$TARGET"; mv "$OLD" "$TARGET"
fi
\${RIPITOUT_OPEN:-open} "$TARGET"
`;

function writeSwapScript(dir) {
  const file = path.join(dir, "install.sh");
  fs.writeFileSync(file, SWAP_SCRIPT, { mode: 0o755 });
  return file;
}

module.exports = {
  PUBLIC_KEY, compareVersions, signedMessage, verifyManifest, check, download, extractApp,
  bundlePath, installProblem, writeSwapScript,
};
