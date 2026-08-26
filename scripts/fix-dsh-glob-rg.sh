#!/usr/bin/env bash
# Re-apply the Termux (android-arm64) ripgrep fix for DSH's glob/grep tools.
#
# Why: @vscode/ripgrep resolves its platform package as
#   @vscode/ripgrep-${process.platform}-${process.arch}
# which on Termux is @vscode/ripgrep-android-arm64 — a package that does not
# exist. Its module evaluation throws "Could not find @vscode/ripgrep-android-
# arm64", so both dsh tools fail with "ripgrep launch failed".
#
# Part 1: shim package @vscode/ripgrep-android-arm64 whose bin/rg symlinks the
#   working system ripgrep (needed by fresh processes / after restart).
# Part 2: patch resolveRgPath() in @deepseek-ai/dsh-tool-fs-search to resolve
#   via require.resolve() (pure filesystem resolution, no module evaluation)
#   with a system-rg fallback — this also bypasses Node's cached-errored
#   @vscode/ripgrep ESM module in the live server process.
# Then hot-reload the plugin: dev_reload_package "dsh-tool-fs-search".
#
# Idempotent. Run it after `npm update -g @deepseek-ai/dsh` if glob/grep break.
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-/data/data/com.termux/files/home/.npm-global/lib/node_modules/@deepseek-ai/dsh}"
RG_SYSTEM="${RG_SYSTEM:-/data/data/com.termux/files/usr/bin/rg}"

[ -x "$RG_SYSTEM" ] || { echo "system rg not found at $RG_SYSTEM" >&2; exit 1; }
# Only require the top-level node_modules: Part 1 creates node_modules/@vscode itself.
[ -d "$DSH_ROOT/node_modules" ] || { echo "DSH node_modules not found: $DSH_ROOT" >&2; exit 1; }

# ---- Part 1: platform-package shim -------------------------------------------
SHIM="$DSH_ROOT/node_modules/@vscode/ripgrep-android-arm64"
mkdir -p "$SHIM/bin"
cat > "$SHIM/package.json" <<'EOF'
{
  "name": "@vscode/ripgrep-android-arm64",
  "version": "1.18.0",
  "description": "Termux shim: resolves rgPath to the system ripgrep (/data/data/com.termux/files/usr/bin/rg); @vscode/ripgrep has no android platform package.",
  "license": "MIT",
  "bin": { "rg": "bin/rg" }
}
EOF
ln -sf "$RG_SYSTEM" "$SHIM/bin/rg"
echo "[1/2] shim ok: $SHIM/bin/rg -> $RG_SYSTEM"

# ---- Part 2: patch resolveRgPath() (exact-string, idempotent) -----------------
PLUGIN="$DSH_ROOT/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js"
[ -f "$PLUGIN" ] || { echo "plugin not found: $PLUGIN" >&2; exit 1; }

node - "$PLUGIN" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
let s = fs.readFileSync(p, "utf8");
if (s.includes('createRequire(import.meta.url)')) {
  console.log("[2/2] plugin already patched (resolveRgPath uses require.resolve)");
  process.exit(0);
}
const oldImport = 'import { MAX_TIMER_DELAY_MS } from "@deepseek-ai/dsh-timeout";';
const oldFn = `function resolveRgPath() {
\trgPathPromise ??= import("@vscode/ripgrep").then((module) => module.rgPath);
\treturn rgPathPromise;
}`;
if (!s.includes(oldImport)) { console.error("unexpected import block; aborting"); process.exit(2); }
if (!s.includes(oldFn)) { console.error("unexpected resolveRgPath source; aborting"); process.exit(2); }
const newFn = `function resolveRgPath() {
\trgPathPromise ??= Promise.resolve().then(() => {
\t\t// Termux compatibility (android-arm64): @vscode/ripgrep ships no
\t\t// platform package; resolve via require.resolve (no module evaluation)
\t\t// with a system-rg fallback.
\t\tconst require = createRequire(import.meta.url);
\t\tconst binaryName = process.platform === "win32" ? "rg.exe" : "rg";
\t\ttry {
\t\t\treturn require.resolve(\`@vscode/ripgrep-\${process.platform}-\${process.arch}/bin/\${binaryName}\`);
\t\t} catch {
\t\t\tconst candidates = process.env.RIPGREP_BIN
\t\t\t\t? [process.env.RIPGREP_BIN]
\t\t\t\t: ["/data/data/com.termux/files/usr/bin/rg", "/usr/bin/rg", "/usr/local/bin/rg"];
\t\t\tfor (const candidate of candidates) {
\t\t\t\tif (candidate && existsSync(candidate)) return candidate;
\t\t\t}
\t\t\tthrow new Error(\`Could not resolve packaged ripgrep for \${process.platform}-\${process.arch} and no system rg was found\`);
\t\t}
\t});
\treturn rgPathPromise;
}`;
s = s.replace(oldImport, oldImport + `\nimport { existsSync } from "node:fs";\nimport { createRequire } from "node:module";`);
s = s.replace(oldFn, newFn);
fs.writeFileSync(p, s);
console.log("[2/2] plugin patched");
NODE

node --check "$PLUGIN"
echo "done. Apply to the live process (unless this just ran through the injector):"
echo "  dev_reload_package \"dsh-tool-fs-search\""