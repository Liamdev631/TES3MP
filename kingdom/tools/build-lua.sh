#!/usr/bin/env bash
# Build the Lua interpreter the engine embeds, so the server-side gate can be tested on the exact
# runtime it will run under. Lua 5.1.5, straight from lua.org, into kingdom/tools/lua-5.1/.
#
#   bash kingdom/tools/build-lua.sh
#
# Needs only curl, tar and make — no root, nothing installed system-wide.

set -euo pipefail

VERSION="5.1.5"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lua-${VERSION}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "fetching lua ${VERSION}"
curl -sSL -o "${WORK}/lua.tar.gz" "https://www.lua.org/ftp/lua-${VERSION}.tar.gz"
tar -xzf "${WORK}/lua.tar.gz" -C "${WORK}"
cd "${WORK}/lua-${VERSION}"

# `make posix` avoids the readline dependency that `make linux` expects.
make posix >/dev/null 2>&1 || make generic >/dev/null 2>&1

install -d "${DEST}/bin"
install -m 0755 src/lua "${DEST}/bin/lua"
"${DEST}/bin/lua" -v
echo "installed to ${DEST}/bin/lua"
