#!/usr/bin/env node
// apply-termux-fixes.mjs — make an installed @deepseek-ai/dsh tree work on
// Android/Termux. Idempotent: safe to re-run after every
// `npm install -g @deepseek-ai/dsh`, which restores pristine files.
//
//   node scripts/apply-termux-fixes.mjs
//
// Every edit is anchor-based. If an upstream anchor is missing the fix FAILS
// LOUDLY instead of silently doing nothing, so a silent no-op can never happen
// (the failure mode the old .patch files had). Nothing here assumes the tree
// is already patched, so it is safe on a completely clean kernel.
//
// Root cause common to several fixes: Android sepolicy denies hardlink(2) in
// app-private storage -> every link()-based "atomic publish" must fall back to
// rename(2)/copyFile(). That is why edits 2, 3 and 4 exist.
//
// Patch order (matters):
//   1. sharp             real module + @img/sharp-wasm32 runtime fallback
//   2. fs-local          link(2) -> rename(2)      (write / edit tools)
//   3. session-persist   link(2) -> rename(2)      (session + worker)
//   4. attachment-local  link(2) -> rename/copyFile (file uploads)
//   5. node-addon-system flock(2) no-op on android
//   6. subprocess-local  android process inspector
//   7. terminal-bash     shell that exists on Termux
//   8. sandbox-local     proot runner
//   9. native-command    termux-open
//  10. directory-picker  android uses zenity
//  11. workspace         archiveSession tolerates unpersisted sessions
//  12. ripgrep           @vscode/ripgrep-android-arm64 shim -> system rg
//  13. bin.js            --expose-internals shebang + exec bit

import {
  existsSync, readFileSync, writeFileSync, copyFileSync, cpSync, rmSync,
  mkdirSync, readdirSync, chmodSync, symlinkSync, unlinkSync, readlinkSync,
} from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const REPO = fileURLToPath(new URL('..', import.meta.url));
const npmRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
const DSH = process.env.DSH_DIR || join(npmRoot, '@deepseek-ai/dsh');
const NM = join(DSH, 'node_modules');
const P = join(NM, '@deepseek-ai');
const RG_SYSTEM = process.env.RG_SYSTEM || '/data/data/com.termux/files/usr/bin/rg';

const C = { g: '\x1b[32m', y: '\x1b[33m', r: '\x1b[31m', c: '\x1b[36m', z: '\x1b[0m', d: '\x1b[2m' };
const ok = (m) => console.log(`  ${C.g}\u2713${C.z} ${m}`);
const warn = (m) => console.log(`  ${C.y}\u26a0${C.z} ${m}`);
const err = (m) => console.log(`  ${C.r}\u2717${C.z} ${m}`);
const step = (m) => console.log(`\n${C.c}\u25b6${C.z} ${m}`);
const skip = (m) => console.log(`  ${C.d}\u00b7${C.z} ${m}`);
const stats = { changed: 0, skipped: 0, missing: 0, failed: 0 };
const touched = new Set();

// <file>.orig-termux is written once, before the first edit of that file.
function backup(file) {
  const b = `${file}.orig-termux`;
  if (!existsSync(b)) copyFileSync(file, b);
}
function sub(src, from, to) {
  const i = src.indexOf(from);
  if (i === -1) throw new Error(`anchor not found: ${from.slice(0, 70).replace(/\n/g, '\\n')}...`);
  if (src.indexOf(from, i + 1) !== -1) throw new Error(`anchor not unique: ${from.slice(0, 70).replace(/\n/g, '\\n')}...`);
  return src.slice(0, i) + to + src.slice(i + from.length);
}
// fix(file, label, marker, transform): marker is the idempotency sentinel.
function fix(file, label, marker, fn) {
  if (!existsSync(file)) { warn(`${label}: file missing (${file})`); stats.missing++; return; }
  const src = readFileSync(file, 'utf8');
  if (src.includes(marker)) { skip(`${label}: already applied`); stats.skipped++; return; }
  try {
    const out = fn(src);
    backup(file);
    writeFileSync(file, out);
    touched.add(file);
    ok(`${label}: patched`);
    stats.changed++;
  } catch (e) { err(`${label}: ${e.message}`); stats.failed++; }
}

// ── 1. sharp ────────────────────────────────────────────────────────────────
const SHARP_MIN = '0.35.4';
function installWasmSharp(version) {
  const stage = join(tmpdir(), `dsh-sharp-wasm-${process.pid}`);
  rmSync(stage, { recursive: true, force: true });
  mkdirSync(stage, { recursive: true });
  writeFileSync(join(stage, 'package.json'), JSON.stringify({ name: 'stage', private: true }));
  try {
    execFileSync('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', `@img/sharp-wasm32@${version}`], { cwd: stage, stdio: 'inherit' });
    for (const [rel, dest] of [
      ['@img/sharp-wasm32', join(NM, '@img/sharp-wasm32')],
      ['@emnapi/runtime', join(NM, '@emnapi/runtime')],
      ['tslib', join(NM, 'tslib')],
    ]) {
      const from = join(stage, 'node_modules', rel);
      if (!existsSync(from)) { warn(`wasm dep not produced: ${rel}`); continue; }
      if (existsSync(dest)) rmSync(dest, { recursive: true, force: true });
      mkdirSync(join(dest, '..'), { recursive: true });
      cpSync(from, dest, { recursive: true });
      ok(`installed ${rel} -> ${dest}`);
    }
  } finally { rmSync(stage, { recursive: true, force: true }); }
}
function fixSharp() {
  step('1/13 sharp: real module + @img/sharp-wasm32 runtime fallback');
  const sharpDir = join(NM, 'sharp');
  const realDir = join(NM, 'sharp.real');
  let version = SHARP_MIN;
  const versionOf = (dir) => existsSync(join(dir, 'package.json'))
    ? (JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).version || '') : '';
  if (versionOf(realDir)) version = versionOf(realDir);
  else if (versionOf(sharpDir)) version = versionOf(sharpDir);
  // Undo a leftover hand-made stub from an earlier repair.
  if (versionOf(sharpDir).includes('stub')) {
    if (existsSync(realDir)) {
      rmSync(sharpDir, { recursive: true, force: true });
      cpSync(realDir, sharpDir, { recursive: true });
      ok('removed sharp stub, restored real sharp');
      stats.changed++;
    } else { warn('stub present but sharp.real missing; reinstall @deepseek-ai/dsh first'); stats.failed++; return; }
  }
  // The official loader itself falls back to @img/sharp-wasm32 when no native
  // binding exists — no stub needed.
  if (!existsSync(join(NM, '@img/sharp-wasm32/index.cjs'))) { installWasmSharp(version); stats.changed++; }
  else skip('@img/sharp-wasm32 already installed');
  try {
    const out = execFileSync(process.execPath, ['-e', 'const s=require("sharp");console.log(`sharp ${s.versions.sharp} / vips ${s.versions.vips}`)'], { cwd: DSH, encoding: 'utf8' });
    ok(`sharp loads: ${out.trim()}`);
  } catch (e) { err(`sharp still does not load: ${String(e.stderr || e.message).split('\n')[0]}`); stats.failed++; }
}

// ── 2. fs-local: write/edit tools ──────────────────────────────────────────
const FSL_FROM = `\t\tif (createIfAbsent !== void 0) try {
\t\t\tawait linkFile(tempPath, absolutePath);
\t\t} catch (error) {
\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
\t\t}`;
const FSL_TO = `\t\tif (createIfAbsent !== void 0) try {
\t\t\tawait linkFile(tempPath, absolutePath);
\t\t} catch (error) {
\t\t\t/* Termux/Android: sepolicy denies link(2) (EACCES/EPERM). Emulate the
\t\t\t * no-replace publish: a present destination keeps the guarded failure,
\t\t\t * otherwise commit with a same-directory atomic rename. This is what
\t\t\t * makes the write/edit file tools usable on Android. */
\t\t\tif (platform === "android" && (error?.code === "EACCES" || error?.code === "EPERM")) {
\t\t\t\tlet present = false;
\t\t\t\ttry {
\t\t\t\t\tawait inspectPublicationTarget(absolutePath);
\t\t\t\t\tpresent = true;
\t\t\t\t} catch (metadataError) {
\t\t\t\t\tif (!isENOENT(metadataError) && !isENOTDIR(metadataError)) throw metadataError;
\t\t\t\t}
\t\t\t\tif (present) await throwGuardedCreateFailure(Object.assign(new Error(\`EEXIST: file already exists, link '\${tempPath}' -> '\${absolutePath}'\`), { code: "EEXIST" }), absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
\t\t\t\telse await rename(tempPath, absolutePath);
\t\t\t} else {
\t\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
\t\t\t}
\t\t}`;
function fixFsLocal() {
  step('2/13 fs-local: link(2) -> rename(2) for the atomic write publish');
  fix(join(P, 'dsh-fs-local/lib/index.js'), 'fs-local writeFileAtomic', 'Termux/Android: sepolicy denies link(2) (EACCES/EPERM). Emulate the', (src) => sub(src, FSL_FROM, FSL_TO));
}

// ── 3. session-persistence ─────────────────────────────────────────────────
const LINK_A_FROM = `\t} catch (error) {
\t\t/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
\t\tif (isEEXIST(error)) return false;
\t\t/* v8 ignore next -- the filesystem error is already complete. */
\t\tthrow error;
\t}`;
const LINK_A_TO = `\t} catch (error) {
\t\t/* Android sepolicy blocks link(2) (EACCES/EPERM); fall back to same-filesystem atomic rename */
\t\tif (error?.code === "EACCES" || error?.code === "EPERM") {
\t\t\tawait internals.fs.rename(staged, currentPath);
\t\t} else {
\t\t\t/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
\t\t\tif (isEEXIST(error)) return false;
\t\t\t/* v8 ignore next -- the filesystem error is already complete. */
\t\t\tthrow error;
\t\t}
\t}`;
const LINK_B_FROM = `\t\ttry {
\t\t\tawait link(tmp, finalPath);
\t\t\tlinked = true;
\t\t} finally {`;
const LINK_B_TO = `\t\ttry {
\t\t\tawait link(tmp, finalPath);
\t\t\tlinked = true;
\t\t} catch (error) {
\t\t\t/* Android sepolicy blocks link(2) (EACCES/EPERM); fall back to same-filesystem atomic rename */
\t\t\tif (error?.code === "EACCES" || error?.code === "EPERM") {
\t\t\t\tawait rename(tmp, finalPath);
\t\t\t\tlinked = true;
\t\t\t} else {
\t\t\t\tthrow error;
\t\t\t}
\t\t} finally {`;
function ensureRenameImport(src) {
  const re = /import \{([^}]*)\} from "node:fs\/promises";/;
  const m = re.exec(src);
  if (!m || /\brename\b/.test(m[1])) return src;
  return src.replace(re, (_x, list) => `import {${list.replace(/\brm\b/, 'rename, rm')}} from "node:fs/promises";`);
}
function fixSessionLink() {
  step('3/13 session-persistence-jsonl: link(2) -> rename(2) fallback');
  const M = 'Android sepolicy blocks link(2)';
  fix(join(P, 'dsh-session-persistence-jsonl/lib/index.js'), 'index.js', M, (src) => {
    src = ensureRenameImport(src);
    src = sub(src, LINK_A_FROM, LINK_A_TO);
    src = sub(src, LINK_B_FROM, LINK_B_TO);
    return src;
  });
  fix(join(P, 'dsh-session-persistence-jsonl/lib/worker.cjs'), 'worker.cjs', M, (src) => sub(src, LINK_A_FROM, LINK_A_TO));
}

// ── 4. attachment-local: file uploads ──────────────────────────────────────
const ATT_ALIAS_FROM = `\t\ttry {
\t\t\tawait link(source, target);
\t\t} catch (error) {
\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
\t\t\tif (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
\t\t\tif (await digestFile(target) !== sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
\t\t}`;
const ATT_ALIAS_TO = `\t\ttry {
\t\t\tawait link(source, target);
\t\t} catch (error) {
\t\t\t/* Termux/Android: sepolicy denies link(2); copy the immutable object to its alias. */
\t\t\tif (error instanceof Error && "code" in error && (error.code === "EACCES" || error.code === "EPERM")) {
\t\t\t\tawait copyFile(source, target, constants.COPYFILE_EXCL);
\t\t\t} else {
\t\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
\t\t\t\tif (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
\t\t\t\tif (await digestFile(target) !== sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
\t\t\t}
\t\t}`;
const ATT_STAGED_FROM = `\t\ttry {
\t\t\tawait link(staged.path, target);
\t\t} catch (error) {
\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
\t\t\tif (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
\t\t\tif (await digestFile(target) !== staged.sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
\t\t}
\t\tawait unlink(staged.path);`;
const ATT_STAGED_TO = `\t\tlet publishedByRename = false;
\t\ttry {
\t\t\tawait link(staged.path, target);
\t\t} catch (error) {
\t\t\t/* Termux/Android: sepolicy denies link(2); commit the staged object with rename. */
\t\t\tif (error instanceof Error && "code" in error && (error.code === "EACCES" || error.code === "EPERM")) {
\t\t\t\tawait rename(staged.path, target);
\t\t\t\tpublishedByRename = true;
\t\t\t} else {
\t\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
\t\t\t\tif (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
\t\t\t\tif (await digestFile(target) !== staged.sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
\t\t\t}
\t\t}
\t\tif (!publishedByRename) await unlink(staged.path);`;
function fixAttachment() {
  step('4/13 attachment-local: link(2) -> rename/copyFile for file uploads');
  const M = 'Termux/Android: sepolicy denies link(2)';
  fix(join(P, 'dsh-attachment-local/lib/index.js'), 'attachment-local', M, (src) => {
    src = sub(src,
      'import { chmod, link, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";',
      'import { chmod, copyFile, link, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";');
    src = sub(src, ATT_ALIAS_FROM, ATT_ALIAS_TO);
    src = sub(src, ATT_STAGED_FROM, ATT_STAGED_TO);
    return src;
  });
}

// ── 5. flock ───────────────────────────────────────────────────────────────
function fixFlock() {
  step('5/13 node-addon-system: flock(2) no-op on android');
  fix(join(P, 'node-addon-system/lib/flock.js'), 'flock.js', 'IS_ANDROID', (src) => {
    src = sub(src, "import { getSystemErrorName } from 'node:util';", "import { getSystemErrorName } from 'node:util';\n\nconst IS_ANDROID = process.platform === 'android';");
    src = sub(src, 'export async function tryLockExclusive(fd) {\n', 'export async function tryLockExclusive(fd) {\n    if (IS_ANDROID) {\n        /* single-process on Termux: in-process write claim already excludes writers */\n        return;\n    }\n');
    return src;
  });
}

// ── 6. subprocess-local ────────────────────────────────────────────────────
function fixSubprocess() {
  step('6/13 subprocess-local: allow android in the process inspector');
  const dir = join(P, 'dsh-subprocess-local/lib');
  if (!existsSync(dir)) { warn('subprocess-local: lib missing'); stats.missing++; return; }
  for (const f of readdirSync(dir)) {
    if (!(f.startsWith('runner-launch-') && f.endsWith('.js'))) continue;
    const file = join(dir, f);
    if (!readFileSync(file, 'utf8').includes('function createProcessInspector(')) continue;
    fix(file, f, 'platform === "android"', (src) => {
      src = sub(src,
        'function createProcessInspector(platform = process.platform, arch = process.arch, internals = DEFAULT_INTERNALS) {\n\tif (platform === "linux")',
        'function createProcessInspector(platform = process.platform, arch = process.arch, internals = DEFAULT_INTERNALS) {\n\tif (platform === "linux" || platform === "android")');
      src = sub(src, 'platform === "linux" && linuxGroupHasLiveMembers(pid) === false', '(platform === "linux" || platform === "android") && linuxGroupHasLiveMembers(pid) === false');
      return src;
    });
  }
}

// ── 7. terminal shell ──────────────────────────────────────────────────────
function fixTerminalShell() {
  step('7/13 terminal-bash: default shell that exists on Termux');
  fix(join(P, 'dsh-terminal-bash/lib/index.js'), 'terminal-bash', 'files/usr/bin/bash', (src) => {
    if (!/import \{ existsSync \} from "node:fs";/.test(src)) src = sub(src, 'import { createRequire } from "node:module";', 'import { existsSync } from "node:fs";\nimport { createRequire } from "node:module";');
    src = sub(src, 'const DEFAULT_BASH_SHELL = "/bin/bash";', 'const DEFAULT_BASH_SHELL = process.platform === "android"\n\t? (existsSync("/data/data/com.termux/files/usr/bin/bash")\n\t\t? "/data/data/com.termux/files/usr/bin/bash"\n\t\t: (existsSync("/system/bin/sh") ? "/system/bin/sh" : "/bin/sh"))\n\t: "/bin/bash";');
    return src;
  });
}

// ── 8. sandbox proot ───────────────────────────────────────────────────────
function fixSandboxProot() {
  step('8/13 sandbox-local: proot runner for android');
  const file = join(P, 'dsh-sandbox-local/lib/index.js');
  if (!existsSync(file)) { warn('sandbox-local: file missing'); stats.missing++; return; }
  if (readFileSync(file, 'utf8').includes('prootProfileArgs')) { skip('sandbox-local: already applied'); stats.skipped++; return; }
  const patchFile = join(REPO, 'patches/07-sandbox-local-proot-runner.patch');
  if (!existsSync(patchFile)) { err('sandbox-local: patch file missing'); stats.failed++; return; }
  try {
    backup(file);
    execFileSync('patch', ['-p1', '--forward', '-i', patchFile], { cwd: join(P, 'dsh-sandbox-local'), stdio: 'inherit' });
    touched.add(file);
    ok('sandbox-local: proot patch applied');
    stats.changed++;
  } catch (e) { err(`sandbox-local: patch failed (${e.message})`); stats.failed++; }
}

// ── 9. native-command ──────────────────────────────────────────────────────
function fixNativeCommand() {
  step('9/13 native-command: termux-open on android');
  fix(join(P, 'dsh-native-command/lib/index.js'), 'native-command', 'termux-open', (src) => {
    src = sub(src, '\tif (platform === "linux") {\n\t\tconst browser = env.BROWSER;\n\t\tif (browser === void 0 || browser === "") return false;\n\t\tawait run(browser, [path], signal);\n\t\treturn true;\n\t}\n\treturn false;', '\tif (platform === "linux") {\n\t\tconst browser = env.BROWSER;\n\t\tif (browser === void 0 || browser === "") return false;\n\t\tawait run(browser, [path], signal);\n\t\treturn true;\n\t}\n\tif (platform === "android") {\n\t\tawait run("termux-open", [path], signal);\n\t\treturn true;\n\t}\n\treturn false;');
    src = sub(src, '\tif (platform === "linux") {\n\t\tif (wsl) {\n\t\t\tawait openWslPath(path, signal, run);\n\t\t\treturn;\n\t\t}\n\t\tawait run("xdg-open", [path], signal);\n\t\treturn;\n\t}\n\tthrow new Error(`native path opener is unsupported on ${platform}`);', '\tif (platform === "android") {\n\t\tawait run("termux-open", [path], signal);\n\t\treturn;\n\t}\n\tif (platform === "linux") {\n\t\tif (wsl) {\n\t\t\tawait openWslPath(path, signal, run);\n\t\t\treturn;\n\t\t}\n\t\tawait run("xdg-open", [path], signal);\n\t\treturn;\n\t}\n\tthrow new Error(`native path opener is unsupported on ${platform}`);');
    src = sub(src, '\tif (platform === "darwin" || platform === "win32") return true;\n\tif (platform !== "linux") return false;', '\tif (platform === "darwin" || platform === "win32") return true;\n\tif (platform === "android") return true;\n\tif (platform !== "linux") return false;');
    return src;
  });
}

// ── 10. directory picker ───────────────────────────────────────────────────
function fixDirectoryPicker() {
  step('10/13 host-directory-picker-native: android uses zenity');
  fix(join(P, 'dsh-host-directory-picker-native/lib/index.js'), 'directory-picker-native', 'platform === "android"', (src) => sub(src,
    'if (platform === "linux") {\n\t\ttry {\n\t\t\treturn outputPath((await run("zenity", [',
    'if (platform === "linux" || platform === "android") {\n\t\ttry {\n\t\t\treturn outputPath((await run("zenity", ['));
}

// ── 11. workspace archive ──────────────────────────────────────────────────
function fixWorkspaceArchive() {
  step('11/13 workspace: archiveSession tolerates unpersisted sessions');
  fix(join(P, 'dsh-workspace/lib/index.js'), 'workspace', 'Termux: skip the sessionKnown()', (src) => sub(src,
    'if (!await this.sessionKnown(sessionId)) throw new WorkspaceUnknownSessionError(sessionId);',
    '// Termux: skip the sessionKnown() existence check. Sessions visible in the\n\t\t\t// UI may be absent from persistence (empty session dirs after an unclean\n\t\t\t// shutdown, or live sessions that were never persisted). Archiving is\n\t\t\t// just appending an id to a list and must not require storage presence.'));
}

// ── 12. ripgrep shim ───────────────────────────────────────────────────────
function fixRipgrepShim() {
  step('12/13 ripgrep: @vscode/ripgrep-android-arm64 shim -> system rg');
  if (!existsSync(RG_SYSTEM)) { warn(`system rg not found at ${RG_SYSTEM} (pkg install ripgrep)`); stats.missing++; return; }
  const shim = join(NM, '@vscode/ripgrep-android-arm64');
  const bin = join(shim, 'bin', 'rg');
  try {
    if (readlinkSync(bin) === RG_SYSTEM && existsSync(join(shim, 'package.json'))) { skip('ripgrep shim already present'); stats.skipped++; return; }
  } catch { /* no shim yet */ }
  mkdirSync(join(shim, 'bin'), { recursive: true });
  writeFileSync(join(shim, 'package.json'), JSON.stringify({
    name: '@vscode/ripgrep-android-arm64',
    version: '1.18.0',
    description: `Termux shim: resolves rgPath to the system ripgrep (${RG_SYSTEM}); @vscode/ripgrep has no android platform package.`,
    license: 'MIT',
    bin: { rg: 'bin/rg' },
  }, null, 2) + '\n');
  try { unlinkSync(bin); } catch { /* missing */ }
  symlinkSync(RG_SYSTEM, bin);
  chmodSync(RG_SYSTEM, 0o755);
  ok(`ripgrep shim -> ${RG_SYSTEM}`);
  stats.changed++;
}

// ── 13. bin.js shebang ─────────────────────────────────────────────────────
function fixBinShebang() {
  step('13/13 dsh bin.js: --expose-internals shebang');
  const bin = join(DSH, 'lib', 'bin.js');
  if (!existsSync(bin)) { warn('bin.js missing'); stats.missing++; return; }
  const src = readFileSync(bin, 'utf8');
  if (src.split('\n', 1)[0].includes('--expose-internals')) { skip('bin.js already patched'); stats.skipped++; return; }
  const out = `#!${process.execPath} --expose-internals\n` + src.slice(src.indexOf('\n') + 1);
  backup(bin);
  writeFileSync(bin, out);
  chmodSync(bin, 0o755);
  touched.add(bin);
  ok(`bin.js shebang -> ${process.execPath} --expose-internals`);
  stats.changed++;
}

// ── run ────────────────────────────────────────────────────────────────────
console.log(`${C.c}Termux fixes for @deepseek-ai/dsh${C.z}\n  dsh root: ${DSH}`);
if (!existsSync(DSH)) { err(`dsh not found at ${DSH}`); process.exit(1); }
fixSharp();
fixFsLocal();
fixSessionLink();
fixAttachment();
fixFlock();
fixSubprocess();
fixTerminalShell();
fixSandboxProot();
fixNativeCommand();
fixDirectoryPicker();
fixWorkspaceArchive();
fixRipgrepShim();
fixBinShebang();

// Syntax-check every edited JavaScript file so a bad anchor can never ship.
step('verify: node --check on every edited JS file');
for (const f of touched) {
  if (!/\.(js|cjs|mjs)$/.test(f)) continue;
  try { execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' }); skip(`ok ${f.replace(DSH, '…')}`); }
  catch (e) { err(`syntax error after patch: ${f}\n${String(e.stderr || '')}`); stats.failed++; }
}

console.log(`\n${C.c}Summary${C.z}: ${C.g}${stats.changed} changed${C.z}, ${stats.skipped} already applied, ${stats.missing} missing, ${stats.failed} failed`);
if (stats.failed > 0) process.exit(1);
console.log(`${C.d}Restart \`dsh web\` so the running process picks up the patched modules.${C.z}`);
