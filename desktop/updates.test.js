// Tests for the app updater: node --test desktop/
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const updates = require("./updates");

const keys = crypto.generateKeyPairSync("ed25519");
const PUB = keys.publicKey.export({ type: "spki", format: "pem" });
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "ripitout-upd-"));

function sign(manifest, key = keys.privateKey) {
  return { manifest, signature: crypto.sign(null, Buffer.from(updates.signedMessage(manifest)), key).toString("base64") };
}

// A local stand-in for GitHub: the releases API, the update manifest and the DMG.
async function fakeGitHub(files) {
  const server = http.createServer((req, res) => {
    const body = files[req.url];
    if (body === undefined) { res.writeHead(404); return res.end(); }
    res.writeHead(200);
    res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, close: () => server.close() };
}

function release(base, version, manifestDoc) {
  const assets = [{ name: `RipItOut-${version}.dmg`, browser_download_url: `${base}/dmg` }];
  if (manifestDoc) assets.push({ name: `RipItOut-${version}.update.json`, browser_download_url: `${base}/manifest` });
  return { tag_name: `v${version}`, html_url: `${base}/notes`, assets };
}

test("versions compare numerically", () => {
  assert.equal(updates.compareVersions("0.10.0", "0.9.9"), 1);
  assert.equal(updates.compareVersions("v0.4.0", "0.4.0"), 0);
  assert.equal(updates.compareVersions("0.4.0", "0.4.1"), -1);
});

test("the manifest signature is checked", () => {
  const m = { version: "0.5.0", file: "RipItOut-0.5.0.dmg", size: 10, sha256: "a".repeat(64) };
  assert.deepEqual(updates.verifyManifest(sign(m), PUB), m);
  assert.throws(() => updates.verifyManifest({ ...sign(m), manifest: { ...m, size: 11 } }, PUB)); // tampered
  const other = crypto.generateKeyPairSync("ed25519").privateKey;
  assert.throws(() => updates.verifyManifest(sign(m, other), PUB));
  assert.throws(() => updates.verifyManifest(sign(m), updates.PUBLIC_KEY)); // test key isn't the app's key
});

test("check finds a newer signed release, and nothing when up to date", async () => {
  const dmg = Buffer.from("not really a dmg");
  const m = { version: "0.5.0", file: "RipItOut-0.5.0.dmg", size: dmg.length,
    sha256: crypto.createHash("sha256").update(dmg).digest("hex") };
  const files = { "/manifest": sign(m), "/dmg": dmg };
  const gh = await fakeGitHub(files);
  try {
    files["/latest"] = release(gh.base, "0.5.0", true);
    const r = await updates.check({ currentVersion: "0.4.0", releasesUrl: `${gh.base}/latest`, publicKey: PUB });
    assert.equal(r.newer, true);
    assert.equal(r.update.url, `${gh.base}/dmg`);
    assert.equal(r.update.sha256, m.sha256);

    const same = await updates.check({ currentVersion: "0.5.0", releasesUrl: `${gh.base}/latest`, publicKey: PUB });
    assert.equal(same.newer, false);

    files["/latest"] = release(gh.base, "0.5.0", false); // no update.json: point to the release page
    const unsigned = await updates.check({ currentVersion: "0.4.0", releasesUrl: `${gh.base}/latest`, publicKey: PUB });
    assert.equal(unsigned.newer, true);
    assert.equal(unsigned.update, null);

    files["/latest"] = release(gh.base, "0.6.0", true); // manifest for another version
    await assert.rejects(updates.check({ currentVersion: "0.4.0", releasesUrl: `${gh.base}/latest`, publicKey: PUB }));
  } finally { gh.close(); }
});

test("download keeps only a file that matches size and hash", async () => {
  const dmg = crypto.randomBytes(100_000);
  const good = { version: "0.5.0", file: "RipItOut-0.5.0.dmg", size: dmg.length,
    sha256: crypto.createHash("sha256").update(dmg).digest("hex") };
  const gh = await fakeGitHub({ "/dmg": dmg });
  const dir = tmp();
  try {
    let progress = 0;
    const file = await updates.download({ ...good, url: `${gh.base}/dmg` }, dir, { onProgress: (got) => { progress = got; } });
    assert.ok(fs.readFileSync(file).equals(dmg));
    assert.equal(progress, dmg.length);

    fs.rmSync(file);
    await assert.rejects(updates.download({ ...good, sha256: "0".repeat(64), url: `${gh.base}/dmg` }, dir));
    await assert.rejects(updates.download({ ...good, size: 10, url: `${gh.base}/dmg` }, dir));
    assert.deepEqual(fs.readdirSync(dir), []);
  } finally { gh.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});

function fakeApp(dir, version) {
  const app = path.join(dir, "Rip It Out.app");
  fs.mkdirSync(path.join(app, "Contents", "MacOS"), { recursive: true });
  fs.writeFileSync(path.join(app, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>run</string>
<key>CFBundleIdentifier</key><string>test.ripitout</string><key>CFBundleShortVersionString</key><string>${version}</string></dict></plist>`);
  fs.writeFileSync(path.join(app, "Contents", "MacOS", "run"), "#!/bin/sh\n", { mode: 0o755 });
  return app;
}

test("the app comes out of the DMG with the announced version", { skip: process.platform !== "darwin" }, () => {
  const dir = tmp();
  try {
    const src = path.join(dir, "src");
    const app = fakeApp(src, "0.5.0");
    assert.equal(spawnSync("codesign", ["--force", "--sign", "-", app]).status, 0);
    const dmg = path.join(dir, "RipItOut-0.5.0.dmg");
    assert.equal(spawnSync("hdiutil", ["create", "-quiet", "-srcfolder", src, "-format", "UDZO", dmg]).status, 0);
    const out = path.join(dir, "out");
    fs.mkdirSync(out);
    const staged = updates.extractApp(dmg, out, "0.5.0");
    assert.ok(fs.existsSync(path.join(staged, "Contents", "MacOS", "run")));
    assert.ok(!fs.existsSync(dmg));

    const dmg2 = path.join(dir, "RipItOut-0.6.0.dmg");
    assert.equal(spawnSync("hdiutil", ["create", "-quiet", "-srcfolder", src, "-format", "UDZO", dmg2]).status, 0);
    assert.throws(() => updates.extractApp(dmg2, out, "0.6.0"), /version 0.5.0/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("the swap script replaces the app after the old one quit", () => {
  const dir = tmp();
  try {
    const target = fakeApp(path.join(dir, "Applications"), "0.4.0");
    const staged = fakeApp(path.join(dir, "update"), "0.5.0");
    const script = updates.writeSwapScript(dir);
    const gone = spawnSync("true").pid; // a process that has already exited
    const r = spawnSync("/bin/bash", [script, String(gone), staged, target], { env: { ...process.env, RIPITOUT_OPEN: "true" }, encoding: "utf8" });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(fs.readFileSync(path.join(target, "Contents", "Info.plist"), "utf8"), /0\.5\.0/);
    assert.ok(!fs.existsSync(staged));
    assert.deepEqual(fs.readdirSync(path.join(dir, "Applications")), ["Rip It Out.app"]);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("updates refuse to run from a DMG or a translocated copy", () => {
  assert.match(updates.installProblem("/Volumes/Rip It Out/Rip It Out.app"), /Applications folder/);
  assert.match(updates.installProblem("/private/var/folders/x/AppTranslocation/y/d/Rip It Out.app"), /Applications folder/);
  assert.equal(updates.bundlePath("/Applications/Rip It Out.app/Contents/MacOS/Rip It Out"), "/Applications/Rip It Out.app");
});
