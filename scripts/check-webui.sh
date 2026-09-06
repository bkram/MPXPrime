#!/usr/bin/env bash
# Render the web dashboard headlessly in every operating mode (see
# scripts/check-webui.cjs). Installs jsdom into a gitignored cache dir on
# first run so the check works offline afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE=".webui-check"
if [ ! -d "$CACHE/node_modules/jsdom" ]; then
    echo "installing jsdom into $CACHE (first run only)..."
    mkdir -p "$CACHE"
    npm install --no-save --no-audit --no-fund --loglevel=error \
        --prefix "$CACHE" jsdom@25 >/dev/null
fi
NODE_PATH="$PWD/$CACHE/node_modules" exec node scripts/check-webui.cjs "$@"
