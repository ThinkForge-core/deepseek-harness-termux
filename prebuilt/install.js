#!/usr/bin/env node
// dsh-termux postinstall (Plan B — precompiled native modules).
//
// Installs a fully patched @deepseek-ai/dsh globally WITHOUT compiling
// anything:
//   1. npm install -g --ignore-scripts @deepseek-ai/dsh@<pinned>
//   2. drop in the prebuilt native modules (bundled in prebuilt/)
//        - node-pty  -> node-pty/build/Release/pty.node
//        - koffi     -> koffi/build/koffi/android_arm64/koffi.node
//   3. apply every Termux fix by running the bundled canonical patcher
//      scripts/apply-termux-fixes.mjs (same anchor-based set install.sh uses:
//      sharp wasm fallback, link->rename for write/edit + sessions +
//      attachments, flock no-op, platform checks, ripgrep shim, shebang).
//
// Everything is idempotent: re-running `npm i -g <tarball>` re-applies the
// fixes and re-drops the natives (npm re-extracts dsh first, which wipes the
// previous copies).

"use strict";

const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

// Only a dsh version whose anchors the bundled patcher knows is safe to pin
// here. Bump together with scripts/apply-termux-fixes.mjs. Overridable via
// DSH_VERSION.
const DSH_VERSION = process.env.DSH_VERSION || "0.1.5-rc.2";
const PKG_DIR = __dirname;

function sh(cmd, opts) {
  try {
    return execSync(cmd, { stdio: "pipe", ...opts }).toString().trim();
  } catch {
    return "";
  }
}

// ── Pre-flight checks ───────────────────────────────────────────────────────
// Fail fast with a clear message instead of a confusing mid-install error.
const [nodeMajor] = process.versions.node.split(".").map(Number);
if (Number(nodeMajor) < 22) {
  console.error(`[ERROR] dsh needs Node.js >= 22.19 (found ${process.version}).`);
  console.error("        On Termux:  pkg install nodejs-lts   (then reopen the shell)");
  process.exit(1);
}
if (process.arch !== "arm64") {
  console.error(`[ERROR] this package ships android-arm64 binaries only (found ${process.arch}).`);
  console.error("        On an arm64 Termux device use the full install:  bash install.sh");
  process.exit(1);
}
if (process.platform !== "android") {
  console.warn("  [WARN] this package targets Termux/Android; continuing anyway");
}
console.log(`  [OK] ${process.platform}-${process.arch}, node ${process.version}`);

// ── Locate the npm global root ──────────────────────────────────────────────
let globalRoot = sh("npm root -g");
if (!globalRoot) {
  globalRoot = path.join(
    process.env.PREFIX || "/data/data/com.termux/files/usr",
    "lib",
    "node_modules",
  );
}
const dshDir = path.join(globalRoot, "@deepseek-ai", "dsh");

// ── Step 1: install dsh (download only, nothing compiles) ──────────────────
console.log(`==> [1/3] Installing @deepseek-ai/dsh@${DSH_VERSION} (no scripts — nothing compiles)`);
function installDsh(registry) {
  const flag = registry ? ` --registry="${registry}"` : "";
  execSync(`npm install -g --ignore-scripts @deepseek-ai/dsh@${DSH_VERSION}${flag}`, {
    stdio: "inherit",
    timeout: 600000,
  });
}
const REGISTRY_FALLBACKS = [null, "https://registry.npmjs.org", "https://registry.npmmirror.com"];
let dshInstalled = false;
for (const registry of REGISTRY_FALLBACKS) {
  try {
    installDsh(registry);
    dshInstalled = true;
    break;
  } catch {
    console.log(`  [WARN] registry ${registry ?? "(user default)"} failed — trying next`);
  }
}
if (!dshInstalled) {
  console.error("  [ERROR] could not install @deepseek-ai/dsh from any registry");
  process.exit(1);
}

// ── Step 2: drop in the prebuilt native modules ─────────────────────────────
console.log("==> [2/3] Installing prebuilt native modules (android-arm64)");
const prebuiltDir = path.join(PKG_DIR, "prebuilt", "android-arm64");
const TARGETS = [
  ["pty.node", path.join(dshDir, "node_modules", "node-pty", "build", "Release", "pty.node")],
  ["koffi.node", path.join(dshDir, "node_modules", "koffi", "build", "koffi", "android_arm64", "koffi.node")],
];
for (const [file, dest] of TARGETS) {
  const src = path.join(prebuiltDir, file);
  if (!fs.existsSync(src)) {
    console.log("  [WARN] prebuilt module missing:", file, "(this package only ships android-arm64)");
    continue;
  }
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, 0o755);
  console.log("  [OK]", file, "->", path.relative(globalRoot, dest));
}

// Verify the natives actually load before touching anything else: catches an
// ABI/Node-version mismatch at install time with a clear message instead of a
// confusing crash at first `dsh web`.
const verify = sh(`node -e "require('${dshDir}/node_modules/node-pty'); require('${dshDir}/node_modules/koffi'); console.log('ok')"`);
if (verify.includes("ok")) {
  console.log("  [OK] node-pty + koffi load");
} else {
  console.error("  [ERROR] the prebuilt native modules failed to load on this Node.");
  console.error("          Node version:", process.version, "| platform:", process.platform, process.arch);
  console.error("          This package ships android-arm64 N-API binaries (Node >= 22.19).");
  process.exit(1);
}

// ── Step 3: apply every Termux fix through the bundled canonical patcher ────
// One patcher for install.sh, fix-dsh-runtime.sh and this postinstall, so the
// three can never drift. It installs the sharp wasm fallback, patches
// link(2)->rename(2) for write/edit + sessions + attachments, stubs flock,
// fixes the android platform checks, adds the ripgrep shim and the
// --expose-internals shebang.
console.log("==> [3/3] Applying Termux runtime fixes");
const patcher = path.join(PKG_DIR, "scripts", "apply-termux-fixes.mjs");
if (!fs.existsSync(patcher)) {
  console.error("  [ERROR] patcher not found in this package:", patcher);
  console.error("          This tarball is stale — rebuild it with scripts/build-prebuilt.sh");
  process.exit(1);
}
try {
  execSync(`node "${patcher}"`, {
    stdio: "inherit",
    env: { ...process.env, DSH_DIR: dshDir },
    timeout: 900000,
  });
} catch {
  console.error("  [ERROR] the Termux fix patcher failed — see the output above.");
  console.error("          Fix that first; starting dsh web with missing patches will misbehave.");
  process.exit(1);
}

// ── Summary ─────────────────────────────────────────────────────────────────
console.log("");
console.log("==> dsh-termux installed!");
console.log("");
console.log("Run:  dsh web");
console.log("");
console.log("Optional extras after first boot:");
console.log("  dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile   # mobile UI");
