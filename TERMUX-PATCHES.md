# Termux / Android fixes for `@deepseek-ai/dsh`

This repository installs DeepSeek Harness on Android/Termux **and makes it
actually run** there. Everything is designed for a *clean kernel*: install a
fresh copy of dsh from npm, then apply one canonical patch set. No manual
edits, no stub packages, no "disable the plugin and hope" workarounds.

## How it fits together

| File | Role |
|------|------|
| `install.sh` | Full from-scratch install: system deps → node headers → `npm install -g @deepseek-ai/dsh` → native addons → **patcher** → verify. |
| `scripts/apply-termux-fixes.mjs` | The one and only patch set. Idempotent, anchor-based, fails loudly. Called by both `install.sh` and `fix-dsh-runtime.sh`, so they cannot drift. |
| `fix-dsh-runtime.sh` | Re-apply the patch set after an upgrade (`npm install -g` restores pristine files). |
| `patches/07-sandbox-local-proot-runner.patch` | Large proot runner patch (applied by the patcher). |
| `patches/koffi-statx.patch` | koffi build patch (applied by `install.sh` before building koffi). |
| `scripts/fix-npm.sh` | Separate recovery tool: clean reinstall of node/npm on Termux. Not part of the normal flow. |
| `scripts/build-prebuilt.sh`, `prebuilt/` | Optional prebuilt tarball machinery. |

```bash
# clean install
bash install.sh
# after every `npm install -g @deepseek-ai/dsh`
bash fix-dsh-runtime.sh
```

## Root cause that drives most patches

Android sepolicy **denies `link(2)` (hardlink) in app-private storage** with
`EACCES`. Upstream uses `link()` as an "atomic publish" primitive in several
places. Every one of them must fall back to `rename(2)` (same filesystem, also
atomic) or `copyFile()`. This is not a Termux bug to work around locally in one
place — it is the same failure in four different subsystems.

Secondary causes: `flock(2)` does not exist in Bionic; sharp has no
android-arm64 native binary; several `process.platform === "linux"` checks do
not include `"android"`.

## Patch order (as applied by `scripts/apply-termux-fixes.mjs`)

| # | Package / file | What changes | Why |
|---|----------------|--------------|-----|
| 1 | `sharp` + `@img/sharp-wasm32` | real `sharp@0.35.4` + official WASM fallback (`@img/sharp-wasm32`, `@emnapi/runtime`, `tslib`) | no android-arm64 native build exists; the official loader itself falls back to `@img/sharp-wasm32`, so image attachments really work |
| 2 | `dsh-fs-local/lib/index.js` | `linkFile()` → on `EACCES/EPERM` emulate the no-replace publish with `rename()` | **makes the `write` / `edit` file tools work** (they publish through a hardlink) |
| 3 | `dsh-session-persistence-jsonl/lib/index.js` + `worker.cjs` | `link()` → `rename()` on `EACCES/EPERM` (3 sites), `rename` added to the import | session create/resume/publish works |
| 4 | `dsh-attachment-local/lib/index.js` | `link()` → `rename()` (staged object) / `copyFile(COPYFILE_EXCL)` (immutable alias) | file uploads and attachments work |
| 5 | `node-addon-system/lib/flock.js` | `tryLockExclusive()` is a no-op on android | Bionic has no `flock(2)`; single-process `dsh web` has no lock contention |
| 6 | `dsh-subprocess-local/lib/runner-launch-*.js` | `platform === "linux" \|\| platform === "android"` | Android otherwise throws "process inspection unsupported" |
| 7 | `dsh-terminal-bash/lib/index.js` | default shell = Termux bash / `/system/bin/sh` | upstream defaults to `/bin/bash`, which does not exist on Termux |
| 8 | `dsh-sandbox-local/lib/index.js` | proot runner + `android` platform chain | `bwrap` needs namespaces Android does not grant |
| 9 | `dsh-native-command/lib/index.js` | `termux-open` for `openPath` / `canOpen` | "open in app" buttons do nothing otherwise |
| 10 | `dsh-host-directory-picker-native/lib/index.js` | `android` uses the zenity branch | native directory picker |
| 11 | `dsh-workspace/lib/index.js` | `archiveSession()` skips the `sessionKnown()` check | sessions visible in the UI but never persisted could not be archived |
| 12 | `node_modules/@vscode/ripgrep-android-arm64` (shim pkg) | package whose `bin/rg` → system `rg` | `@vscode/ripgrep` has no android-arm64 platform package |
| 13 | `dsh/lib/bin.js` | shebang → `node --expose-internals` | dsh needs `--expose-internals` |

Each edited file gets a one-time backup `<file>.orig-termux` next to it.

## Verification

```bash
# all fixes present + syntax-checked
node scripts/apply-termux-fixes.mjs

# quick manual checks
cd "$(npm root -g)/@deepseek-ai/dsh"
node -e "const s=require('sharp');console.log(s.versions.sharp, s.versions.vips)"
grep -c 'sepolicy denies link(2)' node_modules/@deepseek-ai/dsh-fs-local/lib/index.js
```

`dsh web` must be **restarted** after patching: the running process already has
the old modules in memory.

## Rollback

```bash
# one file
cp -a <file>.orig-termux <file> && rm <file>.orig-termux
# sharp
NM="$(npm root -g)/@deepseek-ai/dsh/node_modules"; rm -rf "$NM/sharp" && mv "$NM/sharp.real" "$NM/sharp"
```

## A note on the old approach (removed)

Earlier revisions of this repo shipped ten `.patch` files that targeted an
older kernel; on 0.1.5-rc.2 most either did not apply or applied only partly
(e.g. the session `link()` fix marked one of three real call sites). They were
also eaten silently by `patch --forward`. They are gone. The anchor-based
patcher replaces them: if upstream code changes, it **fails loudly** instead of
pretending success. A hand-made `sharp` stub and a `fix-dsh-sharp.sh` that
disabled `attachment-local` through `cordis.patch.yml` were also removed — the
WASM fallback and the no-op lock make both unnecessary, and disabling
`attachment-local` broke the whole `sessions → session-controller → UI` tree.
