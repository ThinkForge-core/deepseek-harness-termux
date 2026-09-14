#!/usr/bin/env bash
# build-prebuilt.sh — assemble the dsh-termux prebuilt tarballs (Plan B).
#
# Run on an arm64 Termux device that already has a WORKING patched install
# (run install.sh once). Produces two tarballs:
#   dsh-termux.tgz        (layered,  ~360 KB) — small; postinstall pulls dsh
#                          from the npm registry (with npmjs→npmmirror fallback)
#   dsh-termux-full.tgz   (vendored, ~55 MB)  — fully offline; bundles the
#                          entire patched dsh + node_modules incl. natives
#
# Users install either with (URLs go live once attached to a release in this fork):
#   npm i -g https://github.com/ThinkForge-core/deepseek-harness-termux/releases/latest/download/dsh-termux.tgz
#   npm i -g https://github.com/ThinkForge-core/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz
#
# Usage:
#   bash scripts/build-prebuilt.sh                 # uses the global install
#   DSH_DIR=/path/to/dsh bash scripts/build-prebuilt.sh
#   MODES=layered bash scripts/build-prebuilt.sh   # only the layered tarball
#   MODES=full   bash scripts/build-prebuilt.sh    # only the vendored tarball
#
# The natives are N-API (ABI stable), so the tarballs keep working across dsh
# updates; rebuild only when the fix set or native deps change.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_DIR/prebuilt"
MODES="${MODES:-layered full}"

# ── 1. Locate a working patched install ─────────────────────────────────────
if [ -z "${DSH_DIR:-}" ]; then
    DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
fi
if [ ! -f "$DSH_DIR/package.json" ]; then
    echo "[ERROR] no @deepseek-ai/dsh found at $DSH_DIR"
    echo "        Run install.sh first, or set DSH_DIR=/path/to/dsh"
    exit 1
fi
echo "==> Using patched install at: $DSH_DIR"

# Resolve a package the way Node does: walk node_modules upwards from the dsh
# root. `npm install -g` HOISTS these siblings out of the dsh tree; a vendored /
# prebuilt install NESTS them inside it. Hardcoding either one makes this script
# fail on the other — the same bug class already fixed in install.sh and in
# scripts/apply-termux-fixes.mjs.
resolve_pkg_dir() {
    local name="$1" dir="$DSH_DIR" up
    while :; do
        if [ -d "$dir/node_modules/$name" ]; then printf '%s\n' "$dir/node_modules/$name"; return 0; fi
        up="$(dirname "$dir")"
        [ "$up" = "$dir" ] && return 0
        dir="$up"
    done
}

PTY_DIR="$(resolve_pkg_dir node-pty)"
KOFFI_DIR="$(resolve_pkg_dir koffi)"
SHARP_DIR="$(resolve_pkg_dir '@img/sharp-wasm32')"
if [ -z "$PTY_DIR" ]; then
    echo "[ERROR] node-pty not found in any node_modules above $DSH_DIR"
    echo "        Run install.sh first, or set DSH_DIR=/path/to/dsh"
    exit 1
fi
if [ -z "$KOFFI_DIR" ]; then
    echo "[ERROR] koffi not found in any node_modules above $DSH_DIR"
    echo "        Run install.sh first, or set DSH_DIR=/path/to/dsh"
    exit 1
fi

PTY="$PTY_DIR/build/Release/pty.node"

# koffi's native addon lives in one of two places depending on how it got here:
#   * install.sh builds koffi from source and copies the addon to the canonical
#     build/koffi/android_arm64/koffi.node  — this is what prebuilt/install.js
#     drops and what the tarballs are expected to carry;
#   * a plain npm install uses koffi's platform package instead
#     (@koromix/koffi-android-arm64/android_arm64/koffi.node) and has no build/
#     at all. Note that `require('koffi')` still succeeds in that case: the addon
#     is loaded lazily, so a bare require proves nothing about its presence.
KOFFI=""
if [ -d "$KOFFI_DIR/build" ]; then
    KOFFI="$(find "$KOFFI_DIR/build" -type f -name 'koffi.node' 2>/dev/null | head -1 || true)"
fi
KOFFI_PLATFORM="$(find "$(dirname "$KOFFI_DIR")" -path '*@koromix*' -type f -name 'koffi.node' 2>/dev/null | head -1 || true)"

if [ ! -f "$PTY" ]; then
    echo "[ERROR] missing $PTY — run install.sh first"
    exit 1
fi
if [ -z "$KOFFI" ] || [ ! -f "$KOFFI" ]; then
    echo "[ERROR] no source-built koffi addon under $KOFFI_DIR/build"
    if [ -n "$KOFFI_PLATFORM" ]; then
        echo "        koffi here resolves its addon from a platform package:"
        echo "          $KOFFI_PLATFORM"
        echo "        prebuilt/install.js expects the SOURCE-BUILT path"
        echo "        (koffi/build/koffi/android_arm64/koffi.node), so this tree"
        echo "        cannot produce the tarballs as they are currently defined."
        echo "        Build from a tree created by install.sh, or update the"
        echo "        packaging to carry the platform package."
    else
        echo "        Run install.sh first (it builds koffi from source)."
    fi
    exit 1
fi
case "$PTY_DIR" in
    "$DSH_DIR"/*) LAYOUT="nested" ;;
    *)            LAYOUT="hoisted" ;;
esac
echo "    layout   : $LAYOUT"
echo "    pty.node : $PTY"
echo "    koffi    : $KOFFI"

# ── 2. Sanity-check the natives load in this node ───────────────────────────
echo "==> Verifying natives load..."
if ! (cd "$DSH_DIR" && node -e "require('node-pty'); require('koffi'); console.log('    natives OK')"); then
    echo "[ERROR] natives failed to load — rebuild them first (bash install.sh)"
    exit 1
fi

# ── 3a. Layered tarball (small; dsh fetched from the registry at install) ───
build_layered() {
    echo "==> Building layered tarball (dsh-termux.tgz)..."
    STAGE="$(mktemp -d)"
    mkdir -p "$STAGE/package/bin" \
             "$STAGE/package/patches" \
             "$STAGE/package/scripts" \
             "$STAGE/package/prebuilt/android-arm64"

    cp "$PKG_DIR/package.json" "$STAGE/package/"
    cp "$PKG_DIR/install.js"    "$STAGE/package/"
    cp "$PKG_DIR/README.md"     "$STAGE/package/"
    cp "$PKG_DIR/README.zh-CN.md" "$STAGE/package/"
    cp "$PKG_DIR/bin/dsh"       "$STAGE/package/bin/dsh"
    chmod +x "$STAGE/package/bin/dsh"
    cp "$REPO_DIR"/patches/*.patch "$STAGE/package/patches/"
    cp "$REPO_DIR"/scripts/apply-termux-fixes.mjs "$STAGE/package/scripts/"
    cp "$REPO_DIR"/TERMUX-PATCHES.md "$STAGE/package/"
    cp "$PTY"  "$STAGE/package/prebuilt/android-arm64/pty.node"
    cp "$KOFFI" "$STAGE/package/prebuilt/android-arm64/koffi.node"

    OUT="$REPO_DIR/dsh-termux.tgz"
    tar -czf "$OUT" -C "$STAGE" package
    rm -rf "$STAGE"
    echo "    -> $OUT ($(du -h "$OUT" | cut -f1))"
}

# ── 3b. Vendored tarball (full offline; whole patched dsh + node_modules) ───
build_full() {
    echo "==> Building vendored tarball (dsh-termux-full.tgz)..."

    # The vendored tarball is `cp -a "$DSH_DIR/."` — a snapshot that has to be
    # SELF-CONTAINED. That holds only in the nested layout, where the natives
    # live inside the dsh tree. With a hoisted install they sit outside it and
    # the tarball would ship without node-pty/koffi — refuse instead of
    # producing a broken artifact.
    case "$PTY_DIR" in
        "$DSH_DIR"/*) ;;
        *)
            echo "[ERROR] this DSH_DIR is a hoisted install: node-pty lives at"
            echo "        $PTY_DIR"
            echo "        which is outside $DSH_DIR, so it would not travel in the"
            echo "        vendored tarball. Build the full tarball from a vendored"
            echo "        install, or build only the layered one (MODES=layered)."
            return 1
            ;;
    esac

    STAGE="$(mktemp -d)"
    FULL_PKG="$STAGE/package"
    mkdir -p "$FULL_PKG"

    # the whole patched install (lib, config, node_modules incl. natives)
    cp -a "$DSH_DIR/." "$FULL_PKG/"

    # node-pty's install script (prebuild.js) exits 0 only when
    # prebuilds/<platform>-<arch>/ exists — otherwise npm falls back to
    # node-gyp rebuild and tries to COMPILE. Mirror the binary there so a
    # plain `npm i -g` (no --ignore-scripts) never compiles.
    if [ -f "$PTY" ]; then
        mkdir -p "$FULL_PKG/node_modules/node-pty/prebuilds/android-arm64"
        cp "$PTY" \
           "$FULL_PKG/node_modules/node-pty/prebuilds/android-arm64/pty.node"
        chmod 755 "$FULL_PKG/node_modules/node-pty/prebuilds/android-arm64/pty.node"
        echo "    -> node-pty prebuild mirrored (prebuilds/android-arm64/pty.node)"
    fi

    # sharp's wasm fallback must live INSIDE the vendored tree
    if [ ! -d "$FULL_PKG/node_modules/@img/sharp-wasm32" ]; then
        if [ -n "$SHARP_DIR" ] && [ -d "$SHARP_DIR" ]; then
            mkdir -p "$FULL_PKG/node_modules/@img"
            cp -a "$SHARP_DIR" "$FULL_PKG/node_modules/@img/"
        else
            echo "    -> fetching @img/sharp-wasm32 into the vendored tree..."
            (cd "$FULL_PKG" && env -u npm_config_prefix -u npm_config_global \
                npm install @img/sharp-wasm32 --no-save --ignore-scripts > /dev/null 2>&1 || true)
        fi
    fi

    # ship the canonical patcher next to the vendored tree so `npm i -g` later
    # can re-apply fixes with fix-dsh-runtime.sh semantics
    mkdir -p "$FULL_PKG/scripts" "$FULL_PKG/patches"
    cp "$REPO_DIR"/scripts/apply-termux-fixes.mjs "$FULL_PKG/scripts/"
    cp "$REPO_DIR"/patches/*.patch "$FULL_PKG/patches/"

    # verify the vendored tree is self-sufficient
    if ! (cd "$FULL_PKG" && node -e "require('sharp'); require('node-pty'); require('koffi'); console.log('    vendored natives OK')"); then
        echo "[ERROR] vendored tree fails to load — aborting full build"
        return 1
    fi

    # rename + version suffix + bin + bundledDependencies (npm keeps the
    # bundled node_modules without re-fetching — same as the reference package)
    node -e "
        const fs = require('fs');
        const p = '$FULL_PKG/package.json';
        const j = JSON.parse(fs.readFileSync(p, 'utf8'));
        j.name = 'dsh-termux';
        j.version = j.version + '-termux.1';
        j.bin = { dsh: 'lib/bin.js', 'dsh-termux': 'lib/bin.js' };
        j.bundleDependencies = Object.keys(j.dependencies || {});
        j.description = (j.description || '') + ' (vendored Termux build)';
        fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
    "

    # ensure bin.js runs with --expose-internals (HMR)
    BIN_JS="$FULL_PKG/lib/bin.js"
    if [ -f "$BIN_JS" ] && ! head -1 "$BIN_JS" | grep -q -- "--expose-internals"; then
        NODE_BIN="$(command -v node)"
        { printf '#!%s --expose-internals\n' "$NODE_BIN"; tail -n +2 "$BIN_JS"; } > "$BIN_JS.new"
        mv "$BIN_JS.new" "$BIN_JS"
        chmod +x "$BIN_JS"   # the .new rewrite drops +x under umask — restore it
        echo "    -> bin.js shebang patched (--expose-internals)"
    fi

    OUT="$REPO_DIR/dsh-termux-full.tgz"
    tar -czf "$OUT" -C "$STAGE" package
    rm -rf "$STAGE"
    echo "    -> $OUT ($(du -h "$OUT" | cut -f1))"
}

for mode in $MODES; do
    case "$mode" in
        layered) build_layered ;;
        full)    build_full ;;
        *) echo "[WARN] unknown mode: $mode (layered|full)" ;;
    esac
done

echo ""
echo "==> Done. Upload both to a release in this fork, then users install:"
echo "    npm i -g https://github.com/ThinkForge-core/deepseek-harness-termux/releases/latest/download/dsh-termux.tgz"
echo "    npm i -g https://github.com/ThinkForge-core/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz"
