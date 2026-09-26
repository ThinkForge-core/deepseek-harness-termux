#!/data/data/com.termux/files/usr/bin/bash
# recon-dsh.sh — read-only разведка окружения для фикса require-builtin.
# Ничего не устанавливает и не меняет. Просто печатает отчёт.
# Запуск:  bash recon-dsh.sh 2>&1 | tee recon-dsh.txt
set -uo pipefail

hr() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

hr "SYSTEM"
uname -a
echo "uname -o: $(uname -o 2>/dev/null)"
echo "uname -m: $(uname -m 2>/dev/null)"
echo "PREFIX=${PREFIX:-<unset>}"
echo "HOME=$HOME"
echo "SHELL=${SHELL:-<unset>}"
echo "TERMUX_VERSION=${TERMUX_VERSION:-<unset>}"
echo "ANDROID_ROOT=${ANDROID_ROOT:-<unset>}"

hr "PATHS"
echo "PATH=$PATH"
echo "which node: $(command -v node 2>/dev/null || echo none)"
echo "which npm : $(command -v npm  2>/dev/null || echo none)"
echo "npm root -g: $(npm root -g 2>/dev/null || echo none)"
echo "npm prefix -g: $(npm prefix -g 2>/dev/null || echo none)"
echo "npm config get prefix: $(npm config get prefix 2>/dev/null || echo none)"

hr "NODE"
node -v 2>/dev/null || echo "node: MISSING"
node -p "process.arch" 2>/dev/null
node -p "process.platform" 2>/dev/null
node -p "process.versions.modules" 2>/dev/null   # NODE_MODULE_VERSION (ABI, напр. 127/147)
node -p "process.versions.napi" 2>/dev/null      # NAPI version (напр. 9)
node -p "process.config.variables.node_module_version" 2>/dev/null
echo "node binary: $(readlink -f "$(command -v node)" 2>/dev/null)"

hr "TOOLCHAIN"
for t in clang clang++ gcc g++ ar cmake make pkg-config patch git python3 python curl tar which rg; do
  printf '%-10s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done
clang --version 2>/dev/null | head -3
python3 --version 2>/dev/null
cmake --version 2>/dev/null | head -1

hr "DSH PACKAGE"
DSH_DIR="$(npm root -g 2>/dev/null)/@deepseek-ai/dsh"
echo "DSH_DIR=$DSH_DIR"
if [ -f "$DSH_DIR/package.json" ]; then
  node -p "require('$DSH_DIR/package.json').version" 2>/dev/null | sed 's/^/dsh version: /'
  node -p "JSON.stringify(require('$DSH_DIR/package.json').optionalDependencies||{},null,2)" 2>/dev/null
else
  echo "dsh package.json NOT FOUND"
fi

hr "require-builtin PACKAGES (все варианты, где найдены)"
find "$(npm root -g 2>/dev/null)" -maxdepth 6 -type d \
  \( -name 'node-addon-require-builtin*' -o -name 'require-builtin*' \) 2>/dev/null \
  | sed 's/^/  dir: /'

hr "require-builtin FILES (собранные .node / package.json)"
for d in $(find "$(npm root -g 2>/dev/null)" -maxdepth 6 -type d -name 'node-addon-require-builtin*' 2>/dev/null); do
  echo "--- $d"
  cat "$d/package.json" 2>/dev/null | head -60
  echo "  built .node files:"
  find "$d" -type f \( -name '*.node' -o -name '*.so' \) 2>/dev/null | sed 's/^/    /'
  echo "  build/ tree (если есть):"
  find "$d/build" -maxdepth 3 2>/dev/null | sed 's/^/    /'
done

hr "loader / node-addon-native-custom-loader"
LOADER_DIR="$(npm root -g 2>/dev/null)/@deepseek-ai/dsh/node_modules/node-addon-native-custom-loader"
echo "LOADER_DIR=$LOADER_DIR"
ls -la "$LOADER_DIR/lib" 2>/dev/null
echo "--- package.json"
cat "$LOADER_DIR/package.json" 2>/dev/null | head -40

hr "node-addon-require-builtin (обёртка)"
WRAP_DIR="$(npm root -g 2>/dev/null)/@deepseek-ai/dsh/node_modules/node-addon-require-builtin"
echo "WRAP_DIR=$WRAP_DIR"
ls -la "$WRAP_DIR" 2>/dev/null
cat "$WRAP_DIR/package.json" 2>/dev/null | head -60
echo "--- lib/index.js (первые 40 строк)"
head -40 "$WRAP_DIR/lib/index.js" 2>/dev/null

hr "optionalDependencies у loader/wrapper"
for p in "$LOADER_DIR/package.json" "$WRAP_DIR/package.json"; do
  [ -f "$p" ] || continue
  echo "--- $p"
  node -p "JSON.stringify({name:require('$p').name,version:require('$p').version,optionalDependencies:require('$p').optionalDependencies||{},dependencies:require('$p').dependencies||{}},null,2)" 2>/dev/null
done

hr "Есть ли уже зарегистрированный optional-пакет в npm-кэше?"
find "${HOME}/.npm" -type d -name 'node-addon-require-builtin*' 2>/dev/null | sed 's/^/  /' | head -20

hr "NDK / sysroot"
echo "ndk-multilib dir: ${PREFIX:-}/opt/ndk-multilib $([ -d "${PREFIX:-}/opt/ndk-multilib" ] && echo EXISTS || echo missing)"
echo "libandroid-spawn: ${PREFIX:-}/lib/libandroid-spawn.so $([ -f "${PREFIX:-}/lib/libandroid-spawn.so" ] && echo EXISTS || echo missing)"
ls -d "${PREFIX:-}/include" 2>/dev/null && echo "sysroot headers present"

hr "gyp headers cache"
NODE_VER="$(node -v 2>/dev/null | sed 's/^v//')"
NG="$HOME/.cache/node-gyp/$NODE_VER"
echo "NODE_GYP_CACHE=$NG $([ -d "$NG" ] && echo EXISTS || echo missing)"
ls -la "$NG" 2>/dev/null | head
[ -f "$NG/include/node/common.gypi" ] && grep -n 'android_ndk_path' "$NG/include/node/common.gypi" | head

hr "REPO (если запускаешь из клона с патчами)"
[ -f "$REPO_DIR/scripts/apply-termux-fixes.mjs" ] && echo "patcher: FOUND" || echo "patcher: NOT FOUND (норм, если запускаешь отдельно)"
ls -la "$(dirname "$0")" 2>/dev/null

hr "npm/pnpm"
npm -v 2>/dev/null
pnpm -v 2>/dev/null || echo "pnpm: not installed"

hr "DONE"
echo "Сохрани вывод: bash recon-dsh.sh 2>&1 | tee recon-dsh.txt"
