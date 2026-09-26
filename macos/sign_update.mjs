// Writes RipItOut-<version>.update.json next to a release DMG: what the app's update
// button needs to trust the download (see desktop/updates.js).
//
//   node macos/sign_update.mjs dist/RipItOut-0.5.0.dmg
//
// The ed25519 private key comes from UPDATE_SIGNING_KEY (PEM text, the repository
// secret) or the file named in UPDATE_SIGNING_KEY_FILE.
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const { signedMessage, verifyManifest } = require("../desktop/updates.js");

const dmg = process.argv[2];
const match = dmg && path.basename(dmg).match(/^RipItOut-(\d+\.\d+\.\d+)\.dmg$/);
if (!match) { console.error("Usage: node macos/sign_update.mjs dist/RipItOut-<version>.dmg"); process.exit(1); }
const key = process.env.UPDATE_SIGNING_KEY
  || (process.env.UPDATE_SIGNING_KEY_FILE && fs.readFileSync(process.env.UPDATE_SIGNING_KEY_FILE, "utf8"));
if (!key) { console.error("Set UPDATE_SIGNING_KEY or UPDATE_SIGNING_KEY_FILE"); process.exit(1); }

const hash = crypto.createHash("sha256");
for await (const chunk of fs.createReadStream(dmg)) hash.update(chunk);
const manifest = { version: match[1], file: path.basename(dmg), size: fs.statSync(dmg).size, sha256: hash.digest("hex") };
const doc = { manifest, signature: crypto.sign(null, Buffer.from(signedMessage(manifest)), key).toString("base64") };
verifyManifest(doc); // the key must belong to the public key the app ships with

const out = path.join(path.dirname(dmg), `RipItOut-${manifest.version}.update.json`);
fs.writeFileSync(out, JSON.stringify(doc, null, 2) + "\n");
console.log(out);
