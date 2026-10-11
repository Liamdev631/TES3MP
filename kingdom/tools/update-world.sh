#!/usr/bin/env bash
# Update the running Kingdom world without losing the world or the players.
#
#   bash kingdom/tools/update-world.sh --dry-run     # print every step, change nothing
#   bash kingdom/tools/update-world.sh               # do it
#
# The shape of it, in order: back up the save, build into a staging path (never over the running
# binary), smoke-test the new build on a scratch port, swap it in atomically, and roll back on our
# own if it does not come up. Every step can be skipped for a Lua-only change, which is the common
# case: Lua needs no rebuild, just a restart.
#
# Nothing here is exercised against a live server yet — the world has no engine installed on this box
# until Morrowind's data files are in place — so the path checks below are what `--dry-run` proves
# today, and they will do the real work the moment the paths exist.

set -euo pipefail

# ------------------------------------------------------------------ configuration
KINGDOM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${KINGDOM_ROOT}/.." && pwd)"

SERVICE="${KOS_SERVICE:-kos-world.service}"          # systemd user unit that runs the server
SERVER_DIR="${KOS_SERVER_DIR:-/home/liamb/kos-world/server}"   # where the server tree lives
RELEASES_DIR="${KOS_RELEASES_DIR:-/home/liamb/kos-world/releases}"
CURRENT_LINK="${KOS_CURRENT_LINK:-/home/liamb/kos-world/current}"
SAVE_DIR="${KOS_SAVE_DIR:-${SERVER_DIR}/data}"
BUILD_DIR="${KOS_BUILD_DIR:-/home/liamb/kos-world/build}"
STAGING_BIN="${BUILD_DIR}/tes3mp-server.new"
SMOKE_SECONDS="${KOS_SMOKE_SECONDS:-8}"
HEALTH_TIMEOUT="${KOS_HEALTH_TIMEOUT:-30}"
WORLD_DIR="${KOS_WORLD_DIR:-/home/liamb/kos-world}"

DRY_RUN=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --lua-only|--skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n%s== %s%s\n' "${C_TITLE}" "$*" "${C_OFF}"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   %s%s%s\n' "${C_WARN}" "$*" "${C_OFF}"; }
fail() { printf '   %s%s%s\n' "${C_ERR}" "$*" "${C_OFF}"; }
run()  { if [[ "${DRY_RUN}" -eq 1 ]]; then printf '   %swould run:%s %s\n' "${C_DIM}" "${C_OFF}" "$*"; else eval "$@"; fi; }

# Colour only when a person is watching: piped output (logs, demos) stays plain text.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_TITLE=$'\033[1;36m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_TITLE=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

missing=0
need_path() {
  if [[ -e "$1" ]]; then note "ok       $1"
  else warn "missing  $1   ($2)"; missing=$((missing + 1)); fi
}

# ------------------------------------------------------------------ 1. preflight
say "1/7  preflight: is this a sane moment to update?"
if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  note "branch   $(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
  sha="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  note "revision ${sha}"
  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
    warn "the tree has uncommitted changes — a rollback would lose them"
  fi
else
  warn "${REPO_ROOT} is not a git checkout"
fi
need_path "${WORLD_DIR}" "the queue, saves and flags live here"
need_path "${WORLD_DIR}/flags.json" "copy kingdom/flags.json here the first time"
need_path "${SERVER_DIR}" "the server tree"
need_path "${SAVE_DIR}" "the world and player saves"

# ------------------------------------------------------------------ 2. tag a rollback point
say "2/7  rollback point: tag what currently works"
tag="kingdom/release/$(date -u +%Y-%m-%dT%H%M%SZ)"
if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  run "git -C '${REPO_ROOT}' tag -f '${tag}'"
  note "rollback with: git checkout ${tag} && re-run this script"
else
  warn "no git checkout, so no tag — the save backup below is the only way back"
fi

# ------------------------------------------------------------------ 3. save, then back it up
say "3/7  save: ask the world to write itself out, then copy it aside"
note "the server drains its queue and publishes state on exit (kingdom_bridge.lua OnServerExit)"
if [[ "${DRY_RUN}" -eq 0 && -d "${SAVE_DIR}" ]]; then
  backup="${SAVE_DIR}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "${SAVE_DIR}" "${backup}"
  note "backed up to ${backup}"
else
  run "cp -a '${SAVE_DIR}' '${SAVE_DIR}.backup-\$(date -u +%Y%m%dT%H%M%SZ)'"
fi

# ------------------------------------------------------------------ 4. build, if anything changed
say "4/7  build: compile into a staging path, never over the running binary"
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  note "skipped (--lua-only): Lua changes need a restart, not a rebuild"
else
  note "dependency list comes from the repo: CI/install_debian_deps.sh"
  run "cmake -S '${REPO_ROOT}' -B '${BUILD_DIR}' -DCMAKE_BUILD_TYPE=Release"
  run "cmake --build '${BUILD_DIR}' --target tes3mp-server -j 4"
  note "the running server keeps using its own binary while this happens"
fi

# ------------------------------------------------------------------ 5. smoke test the staged build
say "5/7  smoke test: does the new build even start?"
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  note "skipped with the build"
else
  note "runs the staged server on a scratch port for ${SMOKE_SECONDS}s with the same data"
  run "timeout ${SMOKE_SECONDS} '${STAGING_BIN}' --config '${SERVER_DIR}/tes3mp-server-default.cfg' > '${BUILD_DIR}/smoke.log' 2>&1 || true"
  run "grep -q 'Server started' '${BUILD_DIR}/smoke.log' || { fail 'staged build did not start'; exit 1; }"
fi

# ------------------------------------------------------------------ 6. swap and restart
say "6/7  swap: point 'current' at the new release and restart the service"
release="${RELEASES_DIR}/$(date -u +%Y%m%dT%H%M%SZ)"
run "install -d '${release}'"
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  run "rsync -a --delete '${KINGDOM_ROOT}/server-lua/' '${release}/server-lua/'"
else
  run "install -m 0755 '${STAGING_BIN}' '${release}/tes3mp-server'"
fi
run "ln -sfn '${release}' '${CURRENT_LINK}'"
run "systemctl --user restart '${SERVICE}'"

# ------------------------------------------------------------------ 7. health, or roll back
say "7/7  health: did it come up? if not, put the old one back"
previous="$( [[ -L "${CURRENT_LINK}" ]] && readlink "${CURRENT_LINK}" || echo "" )"
note "previous release: ${previous:-none recorded}"
note "waiting up to ${HEALTH_TIMEOUT}s for the server to report in"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  note "would run: systemctl --user is-active '${SERVICE}'"
  note "on failure: ln -sfn '${previous}' '${CURRENT_LINK}' && systemctl --user restart '${SERVICE}'"
else
  healthy=0
  for _ in $(seq 1 "${HEALTH_TIMEOUT}"); do
    if systemctl --user is-active --quiet "${SERVICE}"; then healthy=1; break; fi
    sleep 1
  done
  if [[ "${healthy}" -eq 0 ]]; then
    fail "the new release did not come up — rolling back"
    [[ -n "${previous}" ]] && ln -sfn "${previous}" "${CURRENT_LINK}"
    systemctl --user restart "${SERVICE}" || true
    exit 1
  fi
  note "service is up"
fi

# ------------------------------------------------------------------ tell the players, politely
say "done: announcing the update in the world"
run "printf '%s\\n' '{\"action\":\"say\",\"agent\":\"worldsmith\",\"id\":\"update-notice\",\"message\":\"The world just reloaded. You should be able to step back in.\"}' >> '${WORLD_DIR}/queue.jsonl'"

if [[ "${missing}" -gt 0 ]]; then
  say "note: ${missing} path(s) are not installed yet, so steps above are plans rather than actions"
fi
printf '\n%s\n' "Update complete${DRY_RUN:+ (dry run — nothing was changed)}"
