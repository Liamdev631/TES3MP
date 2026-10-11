#!/usr/bin/env bash
# Runs *inside* the game container: bring up a display, start the world's server, connect a client,
# drive it, record it.
#
#   capture.sh --seconds 30 --out /media/videos/name.mp4 --data /morrowind --game /game \
#              --server-dir /server --cell "Seyda Neen" --login-password 'XXXXX-XXXXX-...'
#
# Why a server: the TES3MP client has no single-player mode — it always connects to a server (proven
# by running it: "Connection failed" is the first thing it says without one). That is the right shape
# for us anyway, because the thing worth filming is *our* world: our scripts, our gate, our agents.
#
# Recording starts before the game does, so a failure still produces a video of what went wrong.

set -uo pipefail

SECONDS_TO_RECORD=30
OUT="/media/videos/morrowind.mp4"
DATA="/morrowind"
GAME="/game"
SERVER_DIR="/server"
CELL="Seyda Neen"
HOST="127.0.0.1"
PORT="25565"
PLAYER_NAME="worldsmith"
LOGIN_PASSWORD=""
WIDTH=1280
HEIGHT=720
DISPLAY_NUM=":99"
CONSOLE="coc"                 # how the drone gets somewhere interesting without a save file
WORK="/work"
LOG="${WORK}/client.log"
SERVER_LOG="${WORK}/server.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) SECONDS_TO_RECORD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --game) GAME="$2"; shift 2 ;;
    --server-dir) SERVER_DIR="$2"; shift 2 ;;
    --cell) CELL="$2"; shift 2 ;;
    --server) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --name) PLAYER_NAME="$2"; shift 2 ;;
    --login-password) LOGIN_PASSWORD="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '[capture] %s\n' "$*"; }

# ------------------------------------------------------------------ 1. the game data
ESM=""
for candidate in "${DATA}/Morrowind.esm" "${DATA}/Data Files/Morrowind.esm" "${DATA}"/*/Morrowind.esm; do
  [[ -f "${candidate}" ]] && ESM="${candidate}" && break
done
if [[ -z "${ESM}" ]]; then
  say "FATAL: Morrowind.esm not found under ${DATA} — nothing can start without it."
  find "${DATA}" -maxdepth 2 \( -iname '*.esm' -o -iname '*.bsa' \) 2>/dev/null | head -5
  exit 4
fi
DATA_DIR="$(dirname "${ESM}")"
say "data:    ${ESM}"

# ------------------------------------------------------------------ 2. a writable copy of the engine
# The client insists on reading its settings from its own directory, so it gets one it can write to.
if [[ ! -x "${WORK}/client/tes3mp" ]]; then
  say "copying the engine into ${WORK} so its configs can be written"
  mkdir -p "${WORK}/client"
  cp -a "${GAME}/." "${WORK}/client/" 2>/dev/null
fi
CLIENT_DIR="${WORK}/client"
CLIENT="${CLIENT_DIR}/tes3mp"
[[ -x "${CLIENT}" ]] || { say "FATAL: no client at ${CLIENT}"; exit 3; }

# ------------------------------------------------------------------ 3. the server's own tree
if [[ -x "${SERVER_DIR}/tes3mp-server" ]]; then
  SERVER_BIN="${SERVER_DIR}/tes3mp-server"
elif [[ -x "${CLIENT_DIR}/tes3mp-server" ]]; then
  SERVER_BIN="${CLIENT_DIR}/tes3mp-server"
else
  SERVER_BIN=""
fi
if [[ -z "${SERVER_BIN}" ]]; then
  say "FATAL: no server binary found (looked in ${SERVER_DIR} and ${CLIENT_DIR})"
  exit 3
fi
say "server:  ${SERVER_BIN}"

mkdir -p "${WORK}/server-home" "${WORK}/saves"
if [[ -d "${SERVER_DIR}/server" ]]; then
  cp -a "${SERVER_DIR}/server/." "${WORK}/server-home/" 2>/dev/null
elif [[ -d "${CLIENT_DIR}/server" ]]; then
  cp -a "${CLIENT_DIR}/server/." "${WORK}/server-home/" 2>/dev/null
fi
if [[ -f "${SERVER_DIR}/tes3mp-server-default.cfg" ]]; then
  cp "${SERVER_DIR}/tes3mp-server-default.cfg" "${WORK}/tes3mp-server-default.cfg"
elif [[ -f "${CLIENT_DIR}/tes3mp-server-default.cfg" ]]; then
  cp "${CLIENT_DIR}/tes3mp-server-default.cfg" "${WORK}/tes3mp-server-default.cfg"
fi
if [[ -f "${WORK}/tes3mp-server-default.cfg" ]]; then
  sed -i -E "s|^localAddress *=.*|localAddress = 127.0.0.1|; s|^port *= *25565|port = ${PORT}|; s|^home *=.*|home = ${WORK}/server-home|" \
    "${WORK}/tes3mp-server-default.cfg"
fi
# The console is how a camera drone gets somewhere interesting; the stock scripts disable it.
if [[ -f "${WORK}/server-home/scripts/config.lua" ]]; then
  sed -i -E "s|^config.allowConsole *=.*|config.allowConsole = true|" "${WORK}/server-home/scripts/config.lua"
fi
# Our own scripts ride along with the stock ones.
if [[ -d /kos-world/scripts ]]; then
  mkdir -p "${WORK}/server-home/scripts/custom"
  cp /kos-world/scripts/*.lua "${WORK}/server-home/scripts/custom/" 2>/dev/null
  say "installed $(ls -1 /kos-world/scripts/*.lua 2>/dev/null | wc -l) kingdom script(s) into custom/"
fi

# ------------------------------------------------------------------ 4. configs
mkdir -p /root/.config/openmw
cat > /root/.config/openmw/openmw.cfg <<CFG
data="${DATA_DIR}"
data="${CLIENT_DIR}/resources"
content=Morrowind.esm
content=Tribunal.esm
content=Bloodmoon.esm
[Video]
resolution_x=${WIDTH}
resolution_y=${HEIGHT}
fullscreen=false
[Game]
screenshots_path=/media/screenshots
skip_intro=true
CFG

# The client's own settings file is complete; ours only changes the connection fields. Writing a
# fresh one instead loses settings the client requires (it dies on a missing `logLevel`), so this
# edits the shipped file rather than replacing it.
if [[ -f "${CLIENT_DIR}/tes3mp-client-default.cfg" ]]; then
  sed -i -E "s|^destinationAddress *=.*|destinationAddress = ${HOST}|; \
             s|^port *= *25565|port = ${PORT}|; \
             s|^username *=.*|username = ${PLAYER_NAME}|" \
    "${CLIENT_DIR}/tes3mp-client-default.cfg"
  if grep -qE "^password *=" "${CLIENT_DIR}/tes3mp-client-default.cfg"; then
    sed -i -E "s|^password *=.*|password = ${LOGIN_PASSWORD}|" "${CLIENT_DIR}/tes3mp-client-default.cfg"
  else
    printf '\n[General]\npassword = %s\n' "${LOGIN_PASSWORD}" >> "${CLIENT_DIR}/tes3mp-client-default.cfg"
  fi
else
  say "WARNING: the client's shipped config is missing; falling back to a minimal one"
  cat > "${CLIENT_DIR}/tes3mp-client-default.cfg" <<CFG
[General]
destinationAddress = ${HOST}
port = ${PORT}
username = ${PLAYER_NAME}
password = ${LOGIN_PASSWORD}
logLevel = 2
CFG
fi

# ------------------------------------------------------------------ 5. display
say "starting Xvfb on ${DISPLAY_NUM} (${WIDTH}x${HEIGHT})"
Xvfb "${DISPLAY_NUM}" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp +extension GLX +render -noreset \
  > "${WORK}/xvfb.log" 2>&1 &
XVFB_PID=$!
export DISPLAY="${DISPLAY_NUM}"
for _ in $(seq 1 30); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.5; done
xdpyinfo >/dev/null 2>&1 || { say "FATAL: display never came up"; cat "${WORK}/xvfb.log"; exit 5; }
say "display ready; renderer: $(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/ {print $2}' | head -1)"

# ------------------------------------------------------------------ 6. record from the start
mkdir -p "$(dirname "${OUT}")"
say "recording ${SECONDS_TO_RECORD}s to ${OUT}"
ffmpeg -loglevel error -y -f x11grab -framerate 24 -video_size "${WIDTH}x${HEIGHT}" \
  -i "${DISPLAY_NUM}" -t "${SECONDS_TO_RECORD}" \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -movflags +faststart \
  "${OUT}" > "${WORK}/ffmpeg.log" 2>&1 &
FFMPEG_PID=$!

# ------------------------------------------------------------------ 7. the world
say "starting the server"
(
  cd "${WORK}"
  "${SERVER_BIN}" > "${SERVER_LOG}" 2>&1
) &
SERVER_PID=$!

for _ in $(seq 1 40); do
  grep -qiE "server started|listening|Waiting for players" "${SERVER_LOG}" 2>/dev/null && break
  sleep 1
done
if ! grep -qiE "server started|listening|Waiting for players" "${SERVER_LOG}" 2>/dev/null; then
  say "the server did not report that it is up; its log says:"
  tail -12 "${SERVER_LOG}" 2>/dev/null
fi

say "starting the client"
(
  cd "${CLIENT_DIR}"
  ./tes3mp --data="${DATA_DIR}" --no-grab > "${LOG}" 2>&1
) &
CLIENT_PID=$!

# ------------------------------------------------------------------ 8. drive it
type_text() { xdotool type --delay 60 -- "$1"; }
press()     { xdotool key --clearmodifiers "$1"; }

sleep 30    # connect, settle, and any login dialog to appear

if [[ -n "${LOGIN_PASSWORD}" ]]; then
  say "answering the login dialog"
  type_text "${LOGIN_PASSWORD}"; sleep 1; press "Return"
  sleep 3
  # a first-ever connection asks for the password twice (set, then confirm)
  if grep -qiE "register|again|confirm" "${SERVER_LOG}" "${LOG}" 2>/dev/null; then
    type_text "${LOGIN_PASSWORD}"; sleep 1; press "Return"
    sleep 3
  fi
fi

say "console: ${CONSOLE} \"${CELL}\""
press "grave"
sleep 2
type_text "${CONSOLE} \"${CELL}\""
sleep 1
press "Return"
sleep 12

say "walking and looking around so the footage has motion"
xdotool mousemove_relative -- 200 0
xdotool keydown w; sleep 4
xdotool mousemove_relative -- 260 0; sleep 3
xdotool keyup w
xdotool keydown a; sleep 2; xdotool keyup a
xdotool mousemove_relative -- -300 40; sleep 2

# ------------------------------------------------------------------ 9. wrap up
say "waiting for the recorder"
wait "${FFMPEG_PID}" 2>/dev/null
kill "${CLIENT_PID}" "${SERVER_PID}" "${XVFB_PID}" 2>/dev/null

if [[ -s "${OUT}" ]]; then
  say "wrote $(du -h "${OUT}" | cut -f1) to ${OUT}"
else
  say "no video produced — see ${LOG} and ${SERVER_LOG}"
  tail -15 "${LOG}" 2>/dev/null
  exit 6
fi
