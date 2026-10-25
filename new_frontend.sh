#!/usr/bin/env bash
# Install the dashboard dependencies (when needed) and start the Vite dev server on :5173.
# Vite 5 needs Node.js 18 or newer; this script checks that before touching node_modules.
set -euo pipefail
cd "$(dirname "$0")/frontend"

fail() { echo; echo "ERROR: $*" >&2; exit 1; }
UPGRADE_HELP="Install Node.js 20 LTS, for example with nvm (no root needed):
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    source ~/.nvm/nvm.sh
    nvm install 20
or on Ubuntu/Debian with NodeSource:
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
Then check 'node --version' shows v20 and re-run ./run_frontend.sh"

command -v node >/dev/null || fail "Node.js was not found.
$UPGRADE_HELP"
command -v npm >/dev/null || fail "npm was not found (it ships with Node.js).
$UPGRADE_HELP"
NODE_VER=$(node --version)
NODE_MAJOR=${NODE_VER#v}; NODE_MAJOR=${NODE_MAJOR%%.*}
if [ "$NODE_MAJOR" -lt 18 ]; then
  fail "Node.js $NODE_VER is too old; the dashboard (Vite 5) needs Node.js 18 or newer.
$UPGRADE_HELP"
fi

# Reinstall when node_modules is missing, incomplete, or was installed by a different Node major version.
STAMP=node_modules/.installed-with-node
if [ ! -x node_modules/.bin/vite ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$NODE_MAJOR" ]; then
  [ -d node_modules ] && echo "Reinstalling dashboard dependencies for Node.js $NODE_VER ..."
  rm -rf node_modules
  if [ -f package-lock.json ]; then npm ci; else npm install; fi \
    || fail "npm install failed (see the messages above). Check your internet/proxy access, then re-run this script."
  echo "$NODE_MAJOR" > "$STAMP"
fi

exec npm run dev -- --host 0.0.0.0
