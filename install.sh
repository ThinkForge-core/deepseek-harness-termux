#!/usr/bin/env bash
# install.sh — fully automated install of @deepseek-ai/dsh on Android/Termux.
#
# Usage:
#   bash install.sh [VERSION]     # VERSION default: latest
#
# The script is designed to run against a CLEAN kernel: it installs dsh from
# npm and then applies every Termux fix through scripts/apply-termux-fixes.mjs
# (idempotent, anchor-based, fails loudly if upstream code moved). Re-running it
# is always safe and repairs a tree that an `npm install -g` has overwritten.
#
# What it fixes and why:
#   * pnpm pinned to @11 — v12+ ships a native @pnpm/exe binary with no
#     android-arm64 build.
#   * koffi.node output path is version-dependent: resolved recursively and
#     copied to the canonical build/koffi/android_arm64/koffi.node.
#   * sharp has no android-arm64 native build -> the official @img/sharp-wasm32
#     runtime fallback is installed instead of a hand-made stub.
#   * hardlink(2) is denied by Android sepolicy -> every link()-based atomic
#     publish (write/edit tools, session files, attachments) falls back to
#     rename(2). See patches section 2-4 of the patcher.

set -euo pipefail

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m' CYAN='\033[0;36m' WHITE='\033[1;37m' BOLD='\033[1m'
readonly DIM='\033[2m' RESET='\033[0m' BG_RED='\033[41m' BG_GREEN='\033[42m'

print_header() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${BLUE}  $1${RESET}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════════${RESET}"
}
print_step()  { echo -e "\n${BOLD}${CYAN}▶ [$1]${RESET} ${BOLD}$2${RESET}"; }
print_ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
print_error() { echo -e "  ${RED}✗${RESET} $1" >&2; }
print_warn()  { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_info()  { echo -e "  ${DIM}→${RESET} $1"; }
print_success() { echo -e "\n${BG_GREEN}${WHITE}  ✓ $1  ${RESET}\n"; }
print_failure() { echo -e "\n${BG_RED}${WHITE}  ✗ $1  ${RESET}\n" >&2; }
print_subheader() { echo -e "\n${MAGENTA}┌─ $1${RESET}"; }
print_subitem()   { echo -e "${MAGENTA}│${RESET}  $1"; }
print_subfooter() { echo -e "${MAGENTA}└─────────────────────────────────────────────────────────────${RESET}"; }

# ── Version selection ────────────────────────────────────────────────────────
TARGET_VERSION="${1:-latest}"
if [ "$TARGET_VERSION" = "latest" ]; then VERSION_DISPLAY="latest"; else VERSION_DISPLAY="v$TARGET_VERSION"; fi

print_header "🚀 DeepSeek DSH Installer for Android/Termux"
echo -e "${BOLD}Target version:${RESET} ${GREEN}$VERSION_DISPLAY${RESET}"
echo -e "${BOLD}Date:${RESET} $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${DIM}─────────────────────────────────────────────────────────────────${RESET}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$REPO_DIR/scripts/apply-termux-fixes.mjs"

if [ "$(uname -o 2>/dev/null)" != "Android" ]; then
    print_warn "This script is designed for Termux (Android). Continuing anyway."
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
pkg_installed() { dpkg -s "$1" > /dev/null 2>&1; }
cmd_exists()    { command -v "$1" > /dev/null 2>&1; }

# koffi >=3 places the built addon under a version-dependent path.
find_koffi_node() {
    find "$1/build" -type f -name 'koffi.node' 2>/dev/null | head -1
}

# ── Step 0: system dependencies ──────────────────────────────────────────────
print_step "0/8" "Checking & installing system dependencies"

print_info "Refreshing package lists (pkg update)..."
if pkg update -y 2>&1 | sed 's/^/    /'; then print_ok "Package lists refreshed."
else print_warn "pkg update failed — continuing with existing lists"; fi

print_subheader "Required packages"
SYSTEM_PKGS=(ndk-sysroot clang binutils cmake make python3 pkg-config patch git proot nodejs npm curl which)
PKGS_TO_INSTALL=()
for pkg in "${SYSTEM_PKGS[@]}"; do
    if pkg_installed "$pkg"; then print_ok "$pkg ${DIM}(installed)${RESET}"
    else print_warn "$pkg ${DIM}(missing)${RESET}"; PKGS_TO_INSTALL+=("$pkg"); fi
done

if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    print_info "Installing: ${PKGS_TO_INSTALL[*]}"
    if ! pkg install -y "${PKGS_TO_INSTALL[@]}" 2>&1 | sed 's/^/    /'; then
        print_error "pkg install failed. Common fixes:"
        echo -e "  ${YELLOW}•${RESET} Run 'pkg upgrade -y' once (stale/broken packages block installs)"
        echo -e "  ${YELLOW}•${RESET} Run 'pkg install -y ${PKGS_TO_INSTALL[*]}' manually to see the real error"
        echo -e "  ${YELLOW}•${RESET} Check your network / Termux mirrors (termux-change-repo)"
        exit 1
    fi
    print_ok "System dependencies installed."
else
    print_ok "All system dependencies satisfied."
fi

print_subheader "Optional packages"
for opt in ndk-multilib libandroid-spawn ripgrep; do
    if pkg_installed "$opt"; then print_ok "$opt ${DIM}(installed)${RESET}"; continue; fi
    print_info "Installing $opt..."
    if pkg install -y "$opt" > /dev/null 2>&1; then print_ok "$opt installed"
    else print_warn "$opt unavailable — continuing without it"; fi
done

print_subheader "Tool verification"
TOOLS=(clang clang++ ar cmake make pkg-config patch git python3 node npm curl which rg)
TOOLS_MISSING=false
for tool in "${TOOLS[@]}"; do
    if cmd_exists "$tool"; then print_ok "$tool ${DIM}($(command -v "$tool"))${RESET}"
    else print_warn "$tool not found on PATH — may cause failures"; TOOLS_MISSING=true; fi
done
$TOOLS_MISSING && print_info "Some tools are missing; continuing anyway."

# ── Step 1: native build environment ─────────────────────────────────────────
print_step "1/8" "Configuring native addon build environment"

NDK_MULTILIB="${PREFIX:-/data/data/com.termux/files/usr}/opt/ndk-multilib"
if [ -d "$NDK_MULTILIB" ]; then
    export ANDROID_NDK_HOME="$NDK_MULTILIB" ANDROID_NDK_ROOT="$NDK_MULTILIB"
    export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path=$NDK_MULTILIB"
    print_ok "ndk-multilib NDK detected: ${CYAN}$NDK_MULTILIB${RESET}"
else
    unset ANDROID_NDK_HOME ANDROID_NDK_ROOT
    export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path="
    print_info "No NDK detected — using system Bionic sysroot"
fi
print_ok "GYP_DEFINES='${CYAN}$GYP_DEFINES${RESET}'"

if [ -f "${PREFIX:-/data/data/com.termux/files/usr}/lib/libandroid-spawn.so" ]; then
    export LDFLAGS="${LDFLAGS:+$LDFLAGS }-landroid-spawn"
    print_ok "LDFLAGS='${CYAN}$LDFLAGS${RESET}' ${DIM}(libandroid-spawn)${RESET}"
fi

export PYTHON="${PYTHON:-$(command -v python3 || command -v python || echo python3)}"
export CC="${CC:-clang}" CXX="${CXX:-clang++}"
print_ok "PYTHON=${CYAN}$PYTHON${RESET}  CC=${CYAN}$CC${RESET}  CXX=${CYAN}$CXX${RESET}"

NODE_VER="$(node -v 2>/dev/null | sed 's/^v//' || true)"
[ -n "$NODE_VER" ] || { print_error "node not found after package install — aborting"; exit 1; }
print_ok "Node.js version: ${CYAN}v$NODE_VER${RESET}"
NODE_GYP_CACHE="$HOME/.cache/node-gyp/$NODE_VER"

# ── Step 2: node headers + common.gypi ───────────────────────────────────────
print_step "2/8" "Ensuring node-gyp headers & patching common.gypi"

if [ -d "$NODE_GYP_CACHE/include/node" ]; then
    print_ok "node-gyp headers cache present ${DIM}($NODE_VER)${RESET}"
else
    print_info "Downloading node headers v$NODE_VER (mirror fallback)..."
    _headers_ok=false
    _tmp="$(mktemp -d)"; _tar="$_tmp/node-v$NODE_VER-headers.tar.gz"
    for _base in "https://nodejs.org/download/release/v$NODE_VER" "https://npmmirror.com/mirrors/node/v$NODE_VER"; do
        _url="$_base/node-v$NODE_VER-headers.tar.gz"
        print_info "Trying $_url"
        if curl -fsSL --connect-timeout 15 --max-time 600 -o "$_tar" "$_url" 2>&1 | sed 's/^/      /'; then
            mkdir -p "$NODE_GYP_CACHE"
            tar -xzf "$_tar" -C "$_tmp" 2>&1 | sed 's/^/      /'
            cp -R "$_tmp/node-v$NODE_VER/include" "$NODE_GYP_CACHE/"
            _iv="$(node -p "require('$(npm root -g 2>/dev/null)/npm/node_modules/node-gyp/package.json').installVersion" 2>/dev/null || echo 9)"
            echo "$_iv" > "$NODE_GYP_CACHE/installVersion"
            rm -rf "$_tmp"; print_ok "Node headers installed to $NODE_GYP_CACHE"; _headers_ok=true; break
        fi
        print_warn "Download failed: $_url"
    done
    rm -rf "$_tmp"
    if ! $_headers_ok; then
        print_error "Could not download node headers for v$NODE_VER"; print_error "Fix your network, then re-run install.sh"; exit 1
    fi
fi

_common_gypi="$NODE_GYP_CACHE/include/node/common.gypi"
if [ -f "$_common_gypi" ] && grep -q 'android_ndk_path' "$_common_gypi" && ! grep -q "'android_ndk_path%'" "$_common_gypi"; then
    print_info "Patching common.gypi with android_ndk_path default..."
    awk '
        /^[[:space:]]*'"'"'?variables'"'"'?[[:space:]]*:[[:space:]]*\{/ && !_done {
            print; print "    '"'"'android_ndk_path%'"'"': '"'"''"'"',        # Termux: default empty (no NDK metadata)"; _done=1; next
        }
        { print }
    ' "$_common_gypi" > "$_common_gypi.tmp" && mv "$_common_gypi.tmp" "$_common_gypi"
    grep -q "'android_ndk_path%'" "$_common_gypi" && print_ok "Patched android_ndk_path default" || print_warn "common.gypi patch did not apply"
elif [ -f "$_common_gypi" ]; then
    print_ok "common.gypi already patched"
fi

# ── Step 3: npm install dsh ──────────────────────────────────────────────────
print_step "3/8" "Installing @deepseek-ai/dsh (no scripts)"

NPM_INSTALL_TIMEOUT="${NPM_INSTALL_TIMEOUT:-600}"
NPM_MIRRORS=("https://registry.npmjs.org" "https://registry.npmmirror.com")
NPM_LOG_FILE="${PREFIX:-/data/data/com.termux/files/usr}/tmp/dsh-npm-install.log"
DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"

DSH_INSTALL_OK=false
if [ -f "$DSH_DIR/package.json" ]; then
    _installed_ver="$(node -p "require('$DSH_DIR/package.json').version" 2>/dev/null || true)"
    if [ "$TARGET_VERSION" = "latest" ]; then
        _latest_ver="$(npm view @deepseek-ai/dsh version 2>/dev/null || true)"
        if [ -n "$_installed_ver" ] && [ "$_installed_ver" = "$_latest_ver" ]; then
            print_ok "@deepseek-ai/dsh@$_installed_ver already installed (latest) — skipping npm install"; DSH_INSTALL_OK=true
        else
            print_info "installed=$_installed_ver latest=$_latest_ver — installing @deepseek-ai/dsh@latest"
        fi
    elif [ -n "$_installed_ver" ] && [ "$_installed_ver" = "$TARGET_VERSION" ]; then
        print_ok "@deepseek-ai/dsh@$_installed_ver already installed — skipping npm install"; DSH_INSTALL_OK=true
    else
        print_info "installed=$_installed_ver target=$TARGET_VERSION — installing @deepseek-ai/dsh@$TARGET_VERSION"
    fi
fi

if ! $DSH_INSTALL_OK; then
    if [ "$TARGET_VERSION" = "latest" ]; then PKG_SPEC="@deepseek-ai/dsh@latest"; else PKG_SPEC="@deepseek-ai/dsh@$TARGET_VERSION"; fi

    for _registry in "${NPM_MIRRORS[@]}"; do
        echo "" > "$NPM_LOG_FILE"
        print_info "Trying registry: $_registry"
        { npm install -g --ignore-scripts "$PKG_SPEC" --registry="$_registry" --foreground-scripts --loglevel verbose; } > >(tee "$NPM_LOG_FILE") 2>&1 &
        _npm_pid=$!
        _last_size=0 _stable_count=0
        while kill -0 "$_npm_pid" 2>/dev/null; do
            sleep 10
            _cur_size=$(stat -c %s "$NPM_LOG_FILE" 2>/dev/null || echo 0)
            if [ "$_cur_size" -eq "$_last_size" ]; then
                _stable_count=$((_stable_count + 1)); _elapsed=$((_stable_count * 10))
                printf "\r  ${DIM}No output for ${_elapsed}s (download stalled?)...${RESET}   "
                if [ "$_elapsed" -ge "$NPM_INSTALL_TIMEOUT" ]; then
                    echo ""; print_error "npm install produced no output for ${NPM_INSTALL_TIMEOUT}s — killing"
                    kill -TERM "$_npm_pid" 2>/dev/null; sleep 2; kill -KILL "$_npm_pid" 2>/dev/null
                    wait "$_npm_pid" 2>/dev/null || true; continue 2
                fi
            else
                _stable_count=0; printf "\r  ${GREEN}✓${RESET} ${DIM}Downloading...${RESET}        "
            fi
            _last_size="$_cur_size"
        done
        echo ""
        if wait "$_npm_pid"; then DSH_INSTALL_OK=true; print_ok "Installation from $_registry successful"; break; fi
    done
fi

if ! $DSH_INSTALL_OK; then
    print_error "All registries failed. Last resort: default npm settings"
    npm install -g --ignore-scripts "$PKG_SPEC" && DSH_INSTALL_OK=true
fi
if ! $DSH_INSTALL_OK; then
    print_error "npm install failed from all sources"
    echo -e "  Try manually: ${CYAN}npm install -g $PKG_SPEC${RESET}"; exit 1
fi

DSH_PKGS="$DSH_DIR/node_modules/@deepseek-ai"
print_ok "Package installed at: ${CYAN}$DSH_DIR${RESET}"

# ── Step 4: build native addons ──────────────────────────────────────────────
print_step "4/8" "Building native addons"

NODE_GYP_BIN="$(dirname "$(dirname "$(command -v npm)")")/lib/node_modules/npm/bin/node-gyp-bin"
[ -d "$NODE_GYP_BIN" ] && export PATH="$NODE_GYP_BIN:$PATH"

KOFFI_DIR="$DSH_DIR/node_modules/koffi"
KOFFI_CANONICAL="$KOFFI_DIR/build/koffi/android_arm64/koffi.node"
KOFFI_BUILD=false

print_subheader "Building koffi native library"
if [ -f "$REPO_DIR/patches/koffi-statx.patch" ] && (cd "$KOFFI_DIR" && patch -p1 --dry-run --forward < "$REPO_DIR/patches/koffi-statx.patch" > /dev/null 2>&1); then
    (cd "$KOFFI_DIR" && patch -p1 --forward < "$REPO_DIR/patches/koffi-statx.patch" > /dev/null 2>&1)
    KOFFI_BUILD=true; print_ok "koffi-statx.patch applied"
elif [ ! -f "$KOFFI_CANONICAL" ] && [ -z "$(find_koffi_node "$KOFFI_DIR")" ]; then
    KOFFI_BUILD=true; print_info "koffi.node missing — building from source"
else
    print_ok "koffi already built with patched sources."
fi

if $KOFFI_BUILD; then
    print_info "Building koffi native lib (this takes a while)..."
    if (cd "$KOFFI_DIR" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS node ./cnoke.cjs -P . -D src/koffi --prebuild --release 2>&1 | sed 's/^/    /'); then
        _found="$(find_koffi_node "$KOFFI_DIR")"
        if [ -n "$_found" ] && [ "$_found" != "$KOFFI_CANONICAL" ]; then
            mkdir -p "$(dirname "$KOFFI_CANONICAL")"; cp -f "$_found" "$KOFFI_CANONICAL"
            print_ok "koffi.node copied: $_found -> $KOFFI_CANONICAL"
        fi
        print_ok "koffi native lib built."
    else
        print_error "koffi build failed!"
        echo -e "  ${YELLOW}•${RESET} Missing cmake: ${CYAN}pkg install cmake${RESET}"
        echo -e "  ${YELLOW}•${RESET} Missing ndk-sysroot: ${CYAN}pkg install ndk-sysroot${RESET}"
        echo -e "  ${YELLOW}•${RESET} CFLAGS/CXXFLAGS override in your environment"
        exit 1
    fi
fi
KOFFI_OUT="$(find_koffi_node "$KOFFI_DIR")"; [ -n "$KOFFI_OUT" ] || KOFFI_OUT="$KOFFI_CANONICAL"

PTY_DIR="$DSH_DIR/node_modules/node-pty"
print_subheader "Building node-pty"
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    print_ok "pty.node already built."
else
    print_info "Building node-pty (Termux bionic target)..."
    if (cd "$PTY_DIR" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS node scripts/prebuild.js 2>&1 | sed 's/^/    /'); then
        print_ok "node-pty prebuilt binary available."
    elif (cd "$PTY_DIR" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS node-gyp rebuild --nodedir="$NODE_GYP_CACHE" 2>&1 | sed 's/^/    /'); then
        print_ok "node-pty compiled."
    else
        print_error "node-pty build failed!"
        echo -e "  ${YELLOW}•${RESET} Missing ndk-sysroot: ${CYAN}pkg install ndk-sysroot${RESET}"
        echo -e "  ${YELLOW}•${RESET} Missing binutils: ${CYAN}pkg install binutils${RESET}"
        echo -e "  ${YELLOW}•${RESET} Missing node headers: ${CYAN}rm -rf $NODE_GYP_CACHE && re-run install.sh${RESET}"
        exit 1
    fi
fi

SUB_DIR="$DSH_PKGS/dsh-subprocess-local"
if [ -f "$SUB_DIR/scripts/ensure-spawn-helper.mjs" ]; then
    (cd "$SUB_DIR" && node scripts/ensure-spawn-helper.mjs 2>&1 | sed 's/^/    /') && \
        print_ok "subprocess spawn-helper restored (chmod 755)"
fi

# ── Step 5: Termux runtime patches ───────────────────────────────────────────
print_step "5/8" "Applying Termux/Android runtime patches"

if [ ! -f "$PATCHER" ]; then
    print_error "patcher not found: $PATCHER"; exit 1
fi
if node "$PATCHER"; then
    print_ok "All Termux runtime patches applied."
else
    print_failure "Some patches failed — see the output above."
    print_error "Do not start dsh web until every patch above is green."
    exit 1
fi

# ── Step 6: web profile plugins (optional) ───────────────────────────────────
print_step "6/8" "Optional web-profile tooling (pnpm + dsh-web-mobile)"

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
WEB_PROFILE_DIR="$DSH_HOME_DIR/profiles/web"

if cmd_exists pnpm; then
    print_ok "pnpm present ($(command -v pnpm))"
else
    print_info "Installing pnpm@11 (pure-JS; v12+ has no android-arm64 native binary)..."
    if npm install -g pnpm@11 2>&1 | sed 's/^/    /'; then print_ok "pnpm@11 installed"; else print_warn "pnpm@11 install failed — plugin step will be skipped"; fi
fi

if [ -f "$WEB_PROFILE_DIR/package.json" ] && grep -q "dsh-mobile-nav" "$WEB_PROFILE_DIR/package.json" 2>/dev/null; then
    print_ok "dsh-web-mobile already installed"
elif cmd_exists pnpm; then
    if node --expose-internals "$DSH_DIR/lib/bin.js" plugin --profile web add github:mexiaosqwq/dsh-web-mobile 2>&1 | sed 's/^/    /'; then
        print_ok "dsh-web-mobile installed"
    else
        print_warn "dsh plugin add failed — install manually later:"
        echo -e "  ${CYAN}node --expose-internals $DSH_DIR/lib/bin.js plugin --profile web add github:mexiaosqwq/dsh-web-mobile${RESET}"
    fi
else
    print_warn "pnpm missing — skipping dsh-web-mobile"
fi

# ── Step 7: verification ─────────────────────────────────────────────────────
print_step "7/8" "Verifying environment"

print_ok "Node.js: ${CYAN}$(node -v 2>/dev/null || echo "not found")${RESET}"
print_ok "dsh dir: ${CYAN}$DSH_DIR${RESET}"
print_ok "dsh version: ${CYAN}$(node -p "require('$DSH_DIR/package.json').version" 2>/dev/null || echo unknown)${RESET}"

print_subheader "Native modules"
_NATIVE_MISSING=false
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    print_ok "node-pty pty.node ${DIM}($(ls -lh "$PTY_DIR/build/Release/pty.node" | awk '{print $5}'))${RESET}"
else print_error "node-pty pty.node ${DIM}(missing)${RESET}"; _NATIVE_MISSING=true; fi
if [ -n "$KOFFI_OUT" ] && [ -f "$KOFFI_OUT" ]; then
    print_ok "koffi koffi.node ${DIM}($(ls -lh "$KOFFI_OUT" | awk '{print $5}'))${RESET}"
else print_error "koffi koffi.node ${DIM}(missing)${RESET}"; _NATIVE_MISSING=true; fi
if $_NATIVE_MISSING; then
    print_failure "Native modules are missing — the install is incomplete."
    exit 1
fi

print_subheader "Patched modules"
_check_patched() { # file, grep-needle, label
    if [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null; then print_ok "$3"
    else print_error "$3 ${DIM}(marker not found: $2)${RESET}"; _PATCH_MISSING=true; fi
}
_PATCH_MISSING=false
_check_patched "$DSH_PKGS/dsh-fs-local/lib/index.js"                              "sepolicy denies link(2)" "fs-local: write/edit link->rename"
_check_patched "$DSH_PKGS/dsh-session-persistence-jsonl/lib/index.js"             "Android sepolicy blocks link(2)" "session-persistence: link->rename"
_check_patched "$DSH_PKGS/dsh-attachment-local/lib/index.js"                      "sepolicy denies link(2)" "attachment-local: link->rename"
_check_patched "$DSH_PKGS/node-addon-system/lib/flock.js"                         "IS_ANDROID" "flock: no-op on android"
_check_patched "$DSH_PKGS/dsh-subprocess-local/lib/index.js"                      "platform === \"android\"" "subprocess: android inspector"
_check_patched "$DSH_PKGS/dsh-terminal-bash/lib/index.js"                         "files/usr/bin/bash" "terminal: Termux shell"
_check_patched "$DSH_PKGS/dsh-sandbox-local/lib/index.js"                         "prootProfileArgs" "sandbox: proot runner"
_check_patched "$DSH_PKGS/dsh-workspace/lib/index.js"                             "Termux: skip the sessionKnown" "workspace: archive fix"
_check_patched "$DSH_DIR/node_modules/@vscode/ripgrep-android-arm64/package.json" "ripgrep-android-arm64" "ripgrep shim"
if $_PATCH_MISSING; then
    print_failure "Some patches are missing — re-run install.sh or bash fix-dsh-runtime.sh."
    exit 1
fi

if (cd "$DSH_DIR" && node -e "require('sharp'); process.exit(0)" 2>/dev/null); then
    print_ok "sharp: ${GREEN}OK${RESET} (wasm fallback) $(cd "$DSH_DIR" && node -e "const s=require('sharp');console.log(s.versions.sharp+' / vips '+s.versions.vips)")"
else print_error "sharp does not load"; exit 1; fi

# ── Step 8: final configuration ──────────────────────────────────────────────
print_step "8/8" "Final configuration"

print_subheader "Shell alias"
_RC_FILE=""
if [ -n "${SHELL:-}" ] && [ "${SHELL##*/}" = "zsh" ]; then _RC_FILE="$HOME/.zshrc"
elif [ -n "${SHELL:-}" ] && [ "${SHELL##*/}" = "bash" ]; then _RC_FILE="$HOME/.bashrc"
elif [ -f "$HOME/.zshrc" ]; then _RC_FILE="$HOME/.zshrc"
else _RC_FILE="$HOME/.bashrc"; fi
[ -f "$_RC_FILE" ] || touch "$_RC_FILE"
print_ok "Shell config for alias: ${CYAN}$_RC_FILE${RESET} (shell=${SHELL:-unknown})"
_DSH_ALIAS="alias dsh='node --expose-internals \$(npm root -g)/@deepseek-ai/dsh/lib/bin.js'"
if grep -q "alias dsh=" "$_RC_FILE" 2>/dev/null; then
    print_ok "dsh alias already present in $_RC_FILE"
else
    echo "$_DSH_ALIAS" >> "$_RC_FILE"
    print_ok "Appended to $_RC_FILE:"; echo -e "    ${CYAN}$_DSH_ALIAS${RESET}"
fi

print_subheader "Runtime smoke test"
if (cd "$DSH_DIR" && node -e "require('node-pty'); process.exit(0)" 2>/dev/null); then
    print_ok "node-pty: ${GREEN}OK${RESET}"
else
    if (cd "$DSH_DIR" && node --expose-internals -e "require('node-pty'); process.exit(0)" 2>/dev/null); then
        print_ok "node-pty: ${GREEN}OK${RESET} ${DIM}(with --expose-internals)${RESET}"
    else
        print_warn "node-pty fails to load — terminal plugin may not work."
    fi
fi
if (cd "$DSH_DIR" && node -e "require('koffi'); process.exit(0)" 2>/dev/null); then
    print_ok "koffi: ${GREEN}OK${RESET}"; else print_warn "koffi fails to load — FFI features may not work"; fi

print_subheader "Bash sandbox"
if [ "$(uname -o)" = "Android" ] && cmd_exists proot; then
    if node --expose-internals -e "require('$DSH_PKGS/dsh-sandbox-local'); console.log('loaded')" 2>/dev/null | grep -q loaded; then
        print_ok "proot runner: ${GREEN}registered${RESET}"
    else print_warn "proot runner: module load issue"; fi
else
    print_info "non-Android or proot missing — skipped"
fi

echo ""
print_success "Installation complete! 🎉"
echo ""
echo -e "${BOLD}${WHITE}Quick start:${RESET}"
echo -e "  ${GREEN}1.${RESET} ${DIM}Run:${RESET} ${CYAN}source $_RC_FILE${RESET} ${DIM}(or open a new terminal)${RESET}"
echo -e "  ${GREEN}2.${RESET} ${DIM}Start the web UI:${RESET} ${CYAN}dsh web${RESET}"
echo -e "  ${GREEN}3.${RESET} ${DIM}Open in browser:${RESET} ${CYAN}http://127.0.0.1:3080/${RESET}"
echo ""
echo -e "${DIM}After any \`npm install -g @deepseek-ai/dsh\` re-apply the fixes with:${RESET}"
echo -e "  ${CYAN}bash $(basename "$REPO_DIR")/fix-dsh-runtime.sh${RESET}"
echo ""
echo -e "${DIM}─────────────────────────────────────────────────────────────────${RESET}"
echo -e "${DIM}Installation log: ${CYAN}$NPM_LOG_FILE${RESET}"
echo ""
