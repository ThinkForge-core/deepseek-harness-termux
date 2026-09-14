#!/usr/bin/env bash
# fix-dsh-runtime.sh — re-apply every Termux/Android fix to an installed
# @deepseek-ai/dsh tree.
#
#   bash fix-dsh-runtime.sh
#
# Run this after `npm install -g @deepseek-ai/dsh` (an upgrade restores the
# whole tree to pristine upstream files) or whenever a dsh feature misbehaves.
# It is idempotent and works on a completely clean dsh tree — nothing here
# depends on the tree already being patched.
#
# The actual work lives in scripts/apply-termux-fixes.mjs so that install.sh
# and this command can never drift apart.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$REPO_DIR/scripts/apply-termux-fixes.mjs"
[ -f "$PATCHER" ] || { echo "patcher not found: $PATCHER" >&2; exit 1; }
exec node "$PATCHER" "$@"
