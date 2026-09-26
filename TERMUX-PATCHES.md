# Termux / Android fixes for `@deepseek-ai/dsh`

This repository installs DeepSeek Harness on Android/Termux **and makes it
actually run** there. Everything is designed for a *clean dsh tree*: install a
fresh copy of dsh from npm, then apply one canonical patch set. No manual
edits, no stub packages, no "disable the plugin and hope" workarounds.

## How it fits together

| File | Role |
|------|------|
| `install.sh` | Full from-scratch install: system deps → node headers → `npm install -g @deepseek-ai/dsh` → native addons → **patcher** → verify. |
| `scripts/apply-termux-fixes.mjs` | The one and only patch set. Idempotent, anchor-based, fails loudly. Called by both `install.sh` and `fix-dsh-runtime.sh`, so they cannot drift. |
| `fix-dsh-runtime.sh` | Re-apply the patch set after an upgrade (`npm install -g` restores pristine files). |
| `patches/07-sandbox-local-proot-runner.patch` | The proot runner additions for `dsh-sandbox-local`. Applied by the patcher, which then verifies every addition by marker. Its `--` separator hunk is superseded by the anchor fix for `confine()` in the patcher: 0.1.7-rc.2 reshaped that code, and a `.patch` hunk that no longer matches is exactly how a half-patched sandbox used to ship. |
| `patches/koffi-statx.patch` | koffi build patch (applied by `install.sh` before building koffi). |
| `scripts/fix-npm.sh` | Separate recovery tool: clean reinstall of node/npm on Termux. Not part of the normal flow. |
| `scripts/build-prebuilt.sh`, `prebuilt/` | Optional prebuilt tarball machinery. |

```bash
# clean install
bash install.sh
# after every `npm install -g @deepseek-ai/dsh`
bash fix-dsh-runtime.sh
```

## Where the packages live (install layout)

Upstream `@deepseek-ai/dsh` is a **meta-package**: the code being patched lives in
sibling packages (`dsh-fs-local`, `dsh-workspace`, …), and their location depends
on how dsh was installed:

| Install method | Layout | Plugin path |
|---|---|---|
| `npm install -g` (what `install.sh` does) | **hoisted** | `<prefix>/lib/node_modules/@deepseek-ai/dsh-fs-local` |
| vendored / prebuilt tarball | **nested** | `<prefix>/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-fs-local` |

Neither the patcher nor `install.sh` may hardcode one of them. Both resolve a
package by walking `node_modules` upwards from the dsh root — exactly like Node's
own resolver — so the nested copy wins when present and the hoisted copy is found
otherwise. This matters for more than "file not found": `sharp` and
`@vscode/ripgrep` are hoisted too, so the `@img/sharp-wasm32` fallback and the
ripgrep shim must be written into the `node_modules` directory the package was
actually resolved from, not into `<dsh>/node_modules`. When they were written to
the wrong place, `sharp` still failed to load even though the patch reported
success.

Verified in a clean room (`npm install --prefix … --ignore-scripts
@deepseek-ai/dsh@0.1.5-rc.2`, no prior state) on both layouts. The pin has since
moved to **0.1.7-rc.2**: the three anchors that release moved (sandbox-local's
`confine()`, terminal-bash's neighbour import, workspace's `archiveSession()`
guard) are handled by shape lists, and each was re-checked against a pristine
0.1.7-rc.2 tree.

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
| 8 | `dsh-sandbox-local/lib/index.js` | proot runner + `android` platform chain + no `--` before the command | `bwrap` needs namespaces Android does not grant; **proot rejects the `--` separator as an unknown option** — with it in the frozen argv, proot dies before the command starts and takes bash plus every file write with it |
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

The patcher ends with a **marker pass**: it re-reads the tree and checks that
every fix it claims to have applied is really on disk, then exits non-zero if
anything is missing. That check exists because a single `.patch` hunk of step 8
failed on 0.1.7-rc.2 and left the proot runner registered with the `--` proot
refuses — the sandbox was dead, and nothing in the run said so. Two habits
follow from that: a fix that cannot be placed must fail the whole step, and
"the step reported success" is worth re-verifying from the file itself.

`dsh web` must be **restarted** after patching: the running process already has
the old modules in memory.

## Rollback

```bash
# one file
cp -a <file>.orig-termux <file> && rm <file>.orig-termux

# sharp — lives where the package was resolved from, so do not hardcode a layout.
# The .real backup marks the right directory: nested in a vendored/prebuilt tree,
# beside the core in a hoisted `npm install -g` tree.
DSH="$(npm root -g)/@deepseek-ai/dsh"; NM="$DSH/node_modules"
[ -d "$NM/sharp.real" ] || NM="$(npm root -g)"
rm -rf "$NM/sharp" && mv "$NM/sharp.real" "$NM/sharp"
```

## A note on the old approach (removed)

Earlier revisions of this repo shipped ten `.patch` files that targeted an
older dsh release; on 0.1.5-rc.2 most either did not apply or applied only partly
(e.g. the session `link()` fix marked one of three real call sites). They were
also eaten silently by `patch --forward`. They are gone. The anchor-based
patcher replaces them: if upstream code changes, it **fails loudly** instead of
pretending success. A hand-made `sharp` stub and a `fix-dsh-sharp.sh` that
disabled `attachment-local` through `cordis.patch.yml` were also removed — the
WASM fallback and the no-op lock make both unnecessary, and disabling
`attachment-local` broke the whole `sessions → session-controller → UI` tree.
