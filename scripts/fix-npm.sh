#!/data/data/com.termux/files/usr/bin/env bash
# fix-npm.sh — Чистая переустановка nodejs + npm на Termux (глобально).
# Ничего, кроме node/npm, не трогает. Установку DSH запускай потом сам:
#   bash install.sh
#
# Запуск:  bash fix-npm.sh            (npm из ветки current)
#          bash fix-npm.sh --lts      (npm из ветки LTS — если current-дебы битые)
# Опция:
#   --lts  ставит nodejs-lts + npm (запасной вариант на случай бага в nodejs)

set -uo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
say() { echo -e "${B}${C}▶${N} $1"; }
ok()  { echo -e "  ${G}✓${N} $1"; }
warn(){ echo -e "  ${Y}⚠${N} $1"; }
err() { echo -e "  ${R}✗${N} $1"; }

USE_LTS=false
[ "${1:-}" = "--lts" ] && USE_LTS=true

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLOBAL_NM="$PREFIX/lib/node_modules"

# ── 1. Удаляем старое: nodejs, npm и весь глобальный каталог npm-модулей ───
say "Удаляю nodejs, npm, nodejs-lts..."
pkg remove -y nodejs npm nodejs-lts >/dev/null 2>&1 || true

say "Стираю глобальную npm-область ($GLOBAL_NM) и кэши..."
rm -rf "$GLOBAL_NM" "$HOME/.npm" "$HOME/.cache/node-gyp" 2>/dev/null

# ── 2. Чистая установка из репозитория Termux ──────────────────────────────
# В современном Termux npm — ОТДЕЛЬНЫЙ пакет (nodejs его не содержит).
# --lts  ставит ветку nodejs-lts вместо nodejs (current).
if $USE_LTS; then
    say "Режим LTS: ставлю nodejs-lts + npm..."
    pkg install -y nodejs-lts npm >/dev/null 2>&1 || { err "pkg install nodejs-lts npm — не удалось."; exit 1; }
else
    say "Ставлю nodejs + npm заново (из репо Termux)..."
    if ! pkg install -y nodejs npm >/dev/null 2>&1; then
        err "pkg install nodejs npm — не удалось. Проверь интернет/зеркало (termux-change-repo)."
        exit 1
    fi
fi

ok "node: $(node -v 2>/dev/null || echo '?')"
ok "npm:  $(npm -v 2>/dev/null || echo '?')"
ok "npm root -g: $GLOBAL_NM"

# ── 3. Проверка целостности (битый socks = причина MODULE_NOT_FOUND) ───────
SOCKS_FILE="$(npm root -g 2>/dev/null)/npm/node_modules/socks/build/index.js"
say "Проверяю целостность npm (socks/build/index.js)..."
if [ -f "$SOCKS_FILE" ]; then
    ok "socks на месте."
else
    warn "socks/build/index.js отсутствует — битый deb npm. Пробую ещё одну переустановку npm..."
    pkg remove -y npm >/dev/null 2>&1 || true
    rm -rf "$PREFIX/lib/node_modules/npm" 2>/dev/null
    pkg install -y npm >/dev/null 2>&1 || true
fi

if [ -f "$SOCKS_FILE" ] && npm ping >/dev/null 2>&1; then
    ok "npm полностью рабочий (socks + сеть ок)."
elif ! $USE_LTS; then
    warn "socks всё ещё отсутствует => баг упаковки npm в ветке nodejs."
    echo ""
    say "Автоматически повторяю на LTS-ветке (nodejs-lts)..."
    bash "$0" --lts
    exit $?
else
    warn "socks отсутствует и в LTS-ветке — это системная проблема зеркала/репо Termux."
    exit 1
fi

# ── 4. Итог ─────────────────────────────────────────────────────────────────
echo ""
ok "node/npm чистые и глобально установлены."
[ $USE_LTS = true ] && ok "использована ветка LTS (nodejs-lts)"
echo -e "${B}Дальше запусти установку DSH родным скриптом:${N}"
echo -e "    ${C}cd ~/Gits_to_compile/deepseek-harness-termux && bash install.sh${N}"
