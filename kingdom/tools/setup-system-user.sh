#!/usr/bin/env bash
# Move the Kingdom's credentials and game process behind a dedicated user, so that no agent — mine
# or Robby's — running as `liamb` can read, replace or forge them. This is the one step that needs
# root; every other part of the Kingdom runs without it.
#
# Review before running, then:  sudo kingdom/tools/setup-system-user.sh
#
# It is idempotent: run it twice and the second run changes nothing.

set -euo pipefail

GAME_USER="${GAME_USER:-kosgame}"
AUTH_STORE_SRC="${AUTH_STORE_SRC:-/home/liamb/kos-auth}"
AUTH_STORE_DST="${AUTH_STORE_DST:-/home/${GAME_USER}/kos-auth}"
KINGDOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TES3MP_DIR="$(cd "${KINGDOM_DIR}/.." && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "this script needs root: sudo $0" >&2
  exit 1
fi

say() { printf '  %s\n' "$*"; }

echo "1. system user ${GAME_USER}"
if id "${GAME_USER}" >/dev/null 2>&1; then
  say "already exists"
else
  # No login shell and no password: the account exists to own files and run one service.
  useradd --system --create-home --shell /usr/sbin/nologin "${GAME_USER}"
  say "created"
fi

echo "2. credentials move out of liamb's reach"
install -d -m 0700 -o "${GAME_USER}" -g "${GAME_USER}" "${AUTH_STORE_DST}"
if [[ -d "${AUTH_STORE_SRC}" ]]; then
  # Copy, verify, then remove: never leave the secrets in two places.
  cp -a "${AUTH_STORE_SRC}/." "${AUTH_STORE_DST}/"
  chown -R "${GAME_USER}:${GAME_USER}" "${AUTH_STORE_DST}"
  chmod 0700 "${AUTH_STORE_DST}"
  find "${AUTH_STORE_DST}" -type f -exec chmod 0600 {} +
  if ! cmp -s "${AUTH_STORE_SRC}/accounts.json" "${AUTH_STORE_DST}/accounts.json" 2>/dev/null; then
    echo "  accounts.json did not copy cleanly — leaving the original in place" >&2
    exit 1
  fi
  rm -rf "${AUTH_STORE_SRC}"
  say "moved to ${AUTH_STORE_DST} (0700, ${GAME_USER} only)"
else
  say "nothing to move (${AUTH_STORE_SRC} does not exist yet)"
fi

echo "3. the game user may ask the tailnet who is connecting"
# `tailscale whois` needs the daemon socket; this grants it to this user alone, rather than
# running the game with elevated privileges.
if command -v tailscale >/dev/null; then
  tailscale set --operator="${GAME_USER}" && say "operator set to ${GAME_USER}"
else
  say "tailscale not on PATH — run: tailscale set --operator=${GAME_USER}"
fi

echo "4. read access to the game tree (read-only: the game must not be able to rewrite itself)"
chmod -R a+rX "${TES3MP_DIR}" 2>/dev/null || true
say "${TES3MP_DIR} is readable by ${GAME_USER}"

cat <<EOF

Done. What changed, in one breath: ${GAME_USER} owns the credentials, the game will run as that
user, and liamb — and therefore every agent on this box — can no longer read or alter them.

Next, point the auth service at the new store:
  KOS_AUTH_DIR=${AUTH_STORE_DST}    (kingdom/auth/kos_auth.py defaults to /home/liamb/kos-auth)
and set that in the service unit or the server's config, then restart the service.
EOF
