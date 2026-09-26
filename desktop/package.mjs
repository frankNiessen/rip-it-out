// Packages the Electron app around the staged Python engine. Called by macos/build.sh
// and windows/build.sh.
//
// Env: STAGE (folder with python/, bin/, licenses/), ICON (.icns, or .ico on Windows),
// OUT, VERSION, optional CODESIGN_IDENTITY (Developer ID) to sign with the hardened runtime.
import { packager } from "@electron/packager";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const { STAGE, ICON, OUT, VERSION, CODESIGN_IDENTITY } = process.env;
const entitlements = path.join(here, "..", "macos", "entitlements.plist");
const windows = process.platform === "win32";

const [appPath] = await packager({
  dir: here,
  name: "Rip It Out",
  executableName: "Rip It Out",
  appBundleId: "io.github.frankniessen.ripitout",
  appCategoryType: "public.app-category.music",
  appVersion: VERSION,
  buildVersion: VERSION,
  platform: windows ? "win32" : "darwin",
  arch: windows ? "x64" : "arm64",
  out: OUT,
  overwrite: true,
  icon: ICON,
  asar: true,
  prune: true,
  ignore: [/^\/package\.mjs$/, /^\/updates\.test\.js$/, /^\/node_modules\/\.cache/],
  extraResource: ["python", "bin", "licenses"].map((d) => path.join(STAGE, d)),
  win32metadata: { CompanyName: "Rip It Out", FileDescription: "Rip It Out", ProductName: "Rip It Out" },
  extendInfo: path.join(here, "..", "macos", "Info.plist"),
  osxSign: CODESIGN_IDENTITY && !windows
    ? {
        identity: CODESIGN_IDENTITY,
        optionsForFile: () => ({ hardenedRuntime: true, entitlements }),
      }
    : undefined,
});
console.log(appPath);
