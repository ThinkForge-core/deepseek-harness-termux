# deepseek-harness-termux

**Run the full [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`) on Android / Termux — no features disabled.**

English | [简体中文](README.zh-CN.md)

---

> [!NOTE]
> **This is a fork of [Vengisk/deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux).**
> The original project is credited below; all clone and install commands on this
> page point at **this** fork, so you get the patch pipeline documented here.
> `upstream` is wired to the original repository, so `git fetch upstream && git
> merge upstream/main` pulls its changes in.

---

`deepseek-harness-termux` is a community-maintained compatibility layer that ports the official `@deepseek-ai/dsh` [agent harness](https://github.com/deepseek-ai/deepseek-harness) to Android environments running [Termux](https://termux.com/). The official npm package is built for glibc-based Linux distributions and depends on several native modules that fail to compile or misbehave on Android's Bionic libc. Instead of disabling plugins that depend on those modules, this repository patches the source code so every feature works on Termux.

Every fix is applied by a single anchor-based patch set — `scripts/apply-termux-fixes.mjs` — that runs against a clean upstream install. It is idempotent and **fails loudly** if upstream code moves, so a silent no-op is impossible. The ordered list of fixes lives in [`TERMUX-PATCHES.md`](TERMUX-PATCHES.md).

## Feature Status

Every plugin is enabled and working in the Termux build:

| Component | Status | Notes |
|---|---|---|
| `dsh web` | ✅ Working | Server runs on `http://127.0.0.1:3080` |
| `dsh headless` | ✅ Working | Single-session headless mode |
| `dsh plugin` | ✅ Working | Plugin management |
| HMR (Hot Reload) | ✅ Working | Launched with `--expose-internals` |
| Subprocess | ✅ Working | `node-pty` compiled against the Termux bionic sysroot |
| Bash Sandbox | ⚠️ Limited | `node-pty` works; `bubblewrap` is blocked by Android sepolicy at runtime and degrades safely (`SandboxUnavailableError`) |
| Permission System | ✅ Working | Restored with `node-pty` |
| Session Persistence | ✅ Fixed | `link(2)` → `rename(2)` fallback for Android sepolicy |
| File tools (`write` / `edit`) | ✅ Fixed | `link(2)` → `rename(2)` in `dsh-fs-local` — without it every file write is denied by Android sepolicy |
| File uploads / attachments | ✅ Fixed | `link(2)` → `rename(2)` / `copyFile()` in `dsh-attachment-local` |
| Image processing | ✅ Working | real `sharp` + the official `@img/sharp-wasm32` fallback (no android-arm64 native binary exists, no stub needed) |
| Bash Terminal (PTY) | ✅ Fixed | Default shell path resolved on Termux (`/usr/bin/bash`) |
| Mobile UI Adaptation | ✅ Auto-installed | Narrow screens (<1024px): sidebar hidden, directory as drawer, full-width conversation; no effect on desktop |

## Prerequisites

- **Android 8+** recommended (older versions may work but are untested)
- **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/) (the Play Store version is unsupported and outdated)
- **Node.js >= 24**, **npm**, and the build toolchain for native modules:
  ```bash
  pkg update -y && pkg upgrade -y
  pkg install -y nodejs-lts binutils make pkg-config clang python cmake patch git proot which ndk-multilib libandroid-spawn
  ```
  (`ndk-multilib` adds the multi-ABI NDK toolchain and `libandroid-spawn` the
  `posix_spawn()` shim — both help on older Android versions. `install.sh`
  installs everything automatically, so if you only run the installer you can
  skip this manual step.)
- **Internet connection** for downloading packages

## Installation

> [!IMPORTANT]
> **Supported dsh version: `0.1.7-rc.2` (default).** The patcher matches upstream
> code by exact anchors, so the patch set is validated against specific releases
> and installed explicitly rather than through a moving tag — that is what the
> default pin is for.
>
> npm's `latest` tag is **not** the newest prerelease, so the pin, not `latest`,
> is what the installer targets by default. The pin is a reproducibility choice,
> not a workaround: a clean-room run applied the complete patch set to both
> `0.1.5-rc.1` and `0.1.5-rc.2` with zero missing and zero failed fixes, and the
> three anchors `0.1.7-rc.2` moved are handled by shape lists and were re-checked
> against a pristine tree of that version. If you pass a version whose anchors
> moved, the patcher **fails loudly** rather than producing a half-patched
> install — and it ends by re-reading every fix from disk, so a half-patched tree
> cannot pass as a successful run.

Two deployment options:

### Plan A — compile on device (install.sh)

Full control, works on any arm64 Termux; compiles `node-pty`/`koffi` once
(clang + cmake + NDK sysroot needed, ~5–10 min):

```bash
# Clone this fork
git clone https://github.com/ThinkForge-core/deepseek-harness-termux.git
cd deepseek-harness-termux

# Run the automated installer (installs dsh, applies patches, builds node-pty)
bash install.sh

# ...or choose explicitly: another pinned version, or the unpinned npm tag
bash install.sh 0.1.5-rc.1
bash install.sh latest
```

The installer is idempotent — re-running it skips already-applied patches and already-built artifacts.

After install, `dsh` is usable directly: the installed `bin.js` shebang is
patched with `--expose-internals` (so npm's `dsh` bin works in any shell),
and a `dsh` alias is auto-appended to `~/.bashrc` (created if missing, or
`~/.zshrc` for zsh) — your existing shell config is never overwritten.

### How installation script work

1. **Installs** `@deepseek-ai/dsh` globally.
2. **Applies the Android runtime fixes** through `scripts/apply-termux-fixes.mjs` (idempotent, anchor-based — see [`TERMUX-PATCHES.md`](TERMUX-PATCHES.md)).
3. **Builds the native addons** (`koffi`, `node-pty`) against the Termux bionic sysroot — the build environment (node headers, `GYP_DEFINES`, the `common.gypi` fix) is prepared and the source patches are applied **before** anything compiles.
4. **Patches `koffi`** to drop the unsupported `statx()` syscall on Android (it does not exist in Bionic; falls back to POSIX `stat()`/`fstat()`).
5. **Installs `@img/sharp-wasm32`** as a portable WebAssembly fallback for image processing (no native build needed).
6. **Installs the mobile UI plugin** [`dsh-web-mobile`](https://github.com/mexiaosqwq/dsh-web-mobile) (by @mexiaosqwq) — hides sidebar on narrow screens, directory becomes overlay drawer, conversation gets full width.
7. **Runs a smoke test** to verify `node-pty` loads and the default shell resolves.

### Plan B — precompiled native modules (no compilation)

No compilation at all: `node-pty` and `koffi` ship prebuilt for android-arm64
(N-API, ABI-stable) and the sources are already patched, so installing is a
plain download + extract.

> [!IMPORTANT]
> **This fork does not publish prebuilt release assets yet** — its Releases page
> is empty, so there is no `releases/latest/download/...` URL to point at. Build
> the tarballs once on this device (Plan A must have succeeded first), then
> install them locally:
>
> ```bash
> bash scripts/build-prebuilt.sh          # -> dsh-termux.tgz + dsh-termux-full.tgz
> npm i -g ./dsh-termux-full.tgz          # ~57 MB, fully self-contained
> dsh web
> ```
>
> Once you attach those two files to a release in this fork, the short form
> becomes available and equivalent:
>
> ```bash
> npm i -g https://github.com/ThinkForge-core/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz
> ```
>
> Do **not** use the upstream fork's release tarballs for a current install: they
> were built from an older dsh (`0.1.0-rc.6` era) and do not match the patch set
> documented here.

`dsh-termux-full.tgz` is the self-contained variant (whole patched dsh +
`node_modules`, ~57 MB). The lighter `dsh-termux.tgz` (~360 KB) instead runs a
postinstall that fetches dsh from the npm registry (npmjs→npmmirror fallback),
applies the patches, and drops in the prebuilt natives — prefer it only when the
~57 MB download is a concern. Details: [`prebuilt/README.md`](prebuilt/README.md).
Maintainers rebuild both with
[`scripts/build-prebuilt.sh`](scripts/build-prebuilt.sh).

## Usage

### Mobile UI Adaptation

The installer automatically installs the [`dsh-web-mobile`](https://github.com/mexiaosqwq/dsh-web-mobile) plugin (by [@mexiaosqwq](https://github.com/mexiaosqwq)). On narrow screens (<1024px):

- Sidebar rail hidden, directory becomes an overlay drawer
- Conversation area takes full width
- Status bar adapted (no content obstruction)
- Settings panel becomes a near-full-width sheet


## Preview

| Session Home (Full Width) | Directory Drawer | Settings Interface |
| --- | --- | --- |
| ![Mobile session home](https://raw.githubusercontent.com/mexiaosqwq/dsh-web-mobile/main/assets/hero.png) | ![Directory drawer](https://raw.githubusercontent.com/mexiaosqwq/dsh-web-mobile/main/assets/drawer.png) | ![Mobile settings interface](https://raw.githubusercontent.com/mexiaosqwq/dsh-web-mobile/main/assets/settings.png) |

### Start

Start the web interface with all plugins enabled:

```bash
node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web
```

Or add an alias to your `~/.bashrc`:

```bash
alias dsh='node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js'
```

The `--expose-internals` flag is required because `cordis-plugin-hmr` accesses Node.js internal modules (e.g. `node:internal/modules`), which are gated by default since Node.js 22.

### Web Search

Two ways to enable web search in the web UI:

1. **Recommended — `dsh-web-search-pro`** (multi-engine: Exa / DuckDuckGo /
   Bing / Jina / platform searches with cache). Installed into the web profile:

   ```bash
   dsh plugin --profile web add dsh-web-search-pro
   # its patch references @anweat/dsh-browser — install it as a plain
   # dependency so the inserted `browser` row resolves at boot:
   cd ~/.dsh/profiles/web && pnpm add @anweat/dsh-browser
   ```

   Then configure your Exa key in `~/.dsh/settings.yaml` (hot-reloaded):

   ```yaml
   web-search-pro:
     exaApiKey: 'exa-...'        # or EXA_API_KEY in ~/.dsh/.credentials.yaml
     engines: [exa, ddg, bing]   # optional; defaults to [ddg,bing,exa,seam,jina]
   ```

   Restart `dsh web` once after installing the plugin.

> [!WARNING]
> Known issue (reproduced on dsh `0.1.0-rc.6`; **not** re-tested on
> `0.1.5-rc.2`, the version this fork validates): installing
> `dsh-web-search-pro@0.1.2`
> together with `@anweat/dsh-browser` broke the shared tool-dispatch layer —
> every tool call (including the GUI's own tools) failed with
> `Cannot read properties of undefined (reading 'prepare')`
> (`scheduler.prepare` in `dsh-tools` where
> `registry[TOOL_RUNTIME_SCHEDULER]` is undefined). Root cause points at the
> plugin's separate in-profile copy of `@deepseek-ai/dsh-tools` shadowing the
> host registry (a `Symbol`-keyed scheduler lookup). Recovery: remove the
> plugin and restart:
> `dsh plugin --profile web remove dsh-web-search-pro`
> If the author publishes a fixed version, retry — and test on a spare port
> (`dsh web --port 3191`) before replacing your live instance.


2. **Built-in `web-search-deepseek`** — speaks DeepSeek's *Anthropic-compatible*
   Messages API (`baseURL` + `/messages`) with the native `web_search_20250305`
   tool. ⚠️ It is **not** an Exa client: pointing its `baseURL` at
   `https://api.exa.ai/search` makes it request `.../search/messages`, which
   returns **404**. Leave its `baseURL` at the default
   `https://api.deepseek.com/anthropic/v1` and use a key valid for the
   endpoint you point it at.

## Patches

All fixes are applied by `scripts/apply-termux-fixes.mjs` in a fixed order.
Most are anchor-based text fixes inside the installed packages; the two large
ones stay as `.patch` files:

| Fix | Package | What it does |
|---|---|---|
| sharp | `sharp` + `@img/sharp-wasm32` | Installs the official WebAssembly fallback so image processing works with no native android-arm64 build |
| fs-local | `dsh-fs-local` | `link(2)` → `rename(2)` fallback: makes the `write`/`edit` file tools work |
| session-persistence | `dsh-session-persistence-jsonl` | `link(2)` → `rename(2)` fallback for session files (3 call sites, incl. the worker) |
| attachment-local | `dsh-attachment-local` | `link(2)` → `rename(2)`/`copyFile()` for uploads and immutable aliases |
| flock | `node-addon-system` | `flock(2)` no-op on Android (Bionic has no such syscall) |
| subprocess-local | `dsh-subprocess-local` | Treats `android` like `linux` for process-group inspection |
| terminal-bash | `dsh-terminal-bash` | Resolves a shell binary that really exists on Termux |
| sandbox-local | `dsh-sandbox-local` | Uses `proot` as the sandbox runner, and never the `--` separator proot rejects ([patch](patches/07-sandbox-local-proot-runner.patch) + anchor fix) |
| native-command | `dsh-native-command` | Opens paths/URLs via `termux-open` on Android |
| directory-picker | `dsh-host-directory-picker-native` | Routes directory picking through the zenity path on Android |
| workspace | `dsh-workspace` | Skips the session-known check when archiving |
| ripgrep | `@vscode/ripgrep-android-arm64` (shim) | Resolves to the system `rg`; `@vscode/ripgrep` ships no android package (see [`docs/termux-ripgrep-fix.md`](docs/termux-ripgrep-fix.md)) |
| bin.js | `@deepseek-ai/dsh` | `--expose-internals` shebang |
| koffi | `koffi` | Conditionally compiles out `statx()` on Android ([patch](patches/koffi-statx.patch)) |

`install.sh` runs this set automatically; after `npm install -g @deepseek-ai/dsh`
re-apply it with `bash fix-dsh-runtime.sh`.

## Compatibility Notes

- **Platform detection**: `process.platform` is `"android"` on Termux, so upstream `platform === "linux"` branches are extended to `platform === "linux" || platform === "android"`.
- **Bash sandbox**: `bubblewrap` requires `user_namespaces` and specific `/proc` access that Android sepolicy denies. The harness detects this at runtime and degrades to a safe `SandboxUnavailableError` instead of crashing — subprocess execution itself still works via `node-pty`.
- **Termux paths**: `termux-open` launches the Android VIEW intent (browser, file viewers, etc.).
- **Install layout**: `@deepseek-ai/dsh` is a meta-package, so the patched code
  lives in sibling packages whose path depends on the install method — a plain
  `npm install -g` **hoists** them to `<prefix>/lib/node_modules`, while the
  prebuilt tarball **nests** them in `<dsh>/node_modules`. The patcher and
  `install.sh` resolve each package by walking `node_modules` upwards (Node's own
  algorithm), so both layouts work; the `@img/sharp-wasm32` fallback and the
  ripgrep shim are written into the `node_modules` their host package actually
  resolves from.

## Project Structure

```
deepseek-harness-termux/
├── README.md                      # This file (English)
├── README.zh-CN.md                # 简体中文 README
├── TERMUX-PATCHES.md              # The ordered Termux fix set (canonical reference)
├── LICENSE                        # MIT License
├── install.sh                     # Clean from-scratch installer (idempotent)
├── fix-dsh-runtime.sh             # Re-apply all fixes after an upgrade
├── docs/
│   └── termux-ripgrep-fix.md      # Ripgrep android-arm64 fix (root cause + recovery)
├── scripts/
│   ├── apply-termux-fixes.mjs     # The patch set itself (idempotent, anchor-based)
│   ├── fix-npm.sh                 # Recovery: clean reinstall of node/npm
│   └── build-prebuilt.sh          # Optional prebuilt tarball builder
└── patches/                       # Large patches applied by the patcher / installer
    ├── 07-sandbox-local-proot-runner.patch
    └── koffi-statx.patch
```

## Acknowledgements

- **[Vengisk](https://github.com/Vengisk)** — original
  [deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux)
  compatibility layer this fork is based on.
- **[DeepSeek AI](https://github.com/deepseek-ai)** for the excellent [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) agent framework.
- **[@mexiaosqwq](https://github.com/mexiaosqwq)** for the [dsh-web-mobile](https://github.com/mexiaosqwq/dsh-web-mobile) mobile UI plugin.
- **Termux Community** for the Android terminal environment.
- **koffi**, **node-pty**, and **sharp** maintainers.

## License

MIT — same as the original [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). See [LICENSE](LICENSE).

---

*Maintained by [ThinkForge-core](https://github.com/ThinkForge-core) — a fork of
[Vengisk/deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux),
not an official DeepSeek product.*