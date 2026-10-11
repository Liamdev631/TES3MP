#!/usr/bin/env bash
# Runs *inside* the game container: bring up a display, start Morrowind, drive it, record it.
#
#   capture.sh --mode single --seconds 30 --out /media/videos/name.mp4 \
#              --data /morrowind --game /game --cell "Seyda Neen"
#
# What it does, in order: Xvfb on a private display, an OpenMW config pointing at the mounted game
# data, the engine started with the client binary, a scripted sequence of keystrokes (open the
# console, teleport into a cell, walk, look around), and ffmpeg recording the display the whole time.
# The recording starts *before* the game does, so a failure still produces a video of what went wrong
# — a black frame with an error on it beats no artefact at all.

set -uo pipefail

MODE="single"            # single (openmw-style client, no server) or mp (connect to a server)
SECONDS_TO_RECORD=30
OUT="/media/videos/morrowind.mp4"
DATA="/morrowind"
GAME="/game"
CELL="Seyda Neen"
SERVER_HOST="127.0.0.1"
SERVER_PORT="25565"
PLAYER_NAME="worldsmith"
PASSWORD=""
WIDTH=1280
HEIGHT=720
DISPLAY_NUM=":99"
SKIP_STARTUP=0
LOG="/work/capture.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --seconds) SECONDS_TO_RECORD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --game) GAME="$2"; shift 2 ;;
    --cell) CELL="$2"; shift 2 ;;
    --server) SERVER_HOST="$2"; shift 2 ;;
    --port) SERVER_PORT="$2"; shift 2 ;;
    --name) PLAYER_NAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --skip-startup) SKIP_STARTUP=1; shift ;;
    --log) LOG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '[capture] %s\n' "$*"; }

# ------------------------------------------------------------------ 1. what are we even running?
CLIENT=""
for candidate in "${GAME}/tes3mp" "${GAME}/openmw" "${GAME}/tes3mp.x86_64" "${GAME}/OpenMW"; do
  [[ -x "${candidate}" ]] && CLIENT="${candidate}" && break
done
if [[ -z "${CLIENT}" ]]; then
  say "no client binary found in ${GAME} — looking for what is there:"
  find "${GAME}" -maxdepth 2 -type f -perm -u+x | head -20
  CLIENT="$(find "${GAME}" -maxdepth 3 -type f \( -name 'tes3mp*' -o -name 'openmw*' \) -perm -u+x | head -1)"
fi
if [[ -z "${CLIENT}" ]]; then
  say "FATAL: no client binary. Exiting before recording so the cause is visible in the log."
  exit 3
fi
say "client: ${CLIENT}"

# ------------------------------------------------------------------ 2. game data
ESM=""
for candidate in "${DATA}/Morrowind.esm" "${DATA}/Data Files/Morrowind.esm" "${DATA}"/*/Morrowind.esm; do
  [[ -f "${candidate}" ]] && ESM="${candidate}" && break
done
if [[ -z "${ESM}" ]]; then
  say "FATAL: Morrowind.esm not found under ${DATA}. Listing what is there:"
  find "${DATA}" -maxdepth 2 -iname '*.esm' -o -maxdepth 2 -iname '*.bsa' 2>/dev/null | head -10
  say "The engine cannot start without the game data; nothing to record."
  exit 4
fi
say "data:   ${ESM}"

# ------------------------------------------------------------------ 3. configs
mkdir -p /root/.config/openmw /work/saves
DATA_DIR="$(dirname "${ESM}")"

cat > /root/.config/openmw/openmw.cfg <<CFG
data="${DATA_DIR}"
data="/game/resources"
content=Morrowind.esm
content=Tribunal.esm
content=Bloodmoon.esm
[Video]
resolution_x=${WIDTH}
resolution_y=${HEIGHT}
fullscreen=false
vsync=false
[Game]
screenshots_path=/media/screenshots
skip_intro=true
[General]
screenshot format=png
CFG

cat > /root/.config/openmw/settings.cfg <<CFG
[Video]
resolution x = ${WIDTH}
resolution y = ${HEIGHT}
fullscreen = false
antialiasing = 0
[Camera]
field of view = 75
[General]
smooth movement = true
[Input]
always run = true
CFG

if [[ "${MODE}" == "mp" ]]; then
  cat > /root/.config/openmw/tes3mp-client-default.cfg <<CFG
[General]
destinationAddress = ${SERVER_HOST}
port = ${SERVER_PORT}
username = ${PLAYER_NAME}
password = ${PASSWORD}
CFG
fi

# ------------------------------------------------------------------ 4. display
say "starting Xvfb on ${DISPLAY_NUM} at ${WIDTH}x${HEIGHT}"
Xvfb "${DISPLAY_NUM}" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp +extension GLX +render -noreset \
  > /work/xvfb.log 2>&1 &
XVFB_PID=$!
export DISPLAY="${DISPLAY_NUM}"
for _ in $(seq 1 30); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.5; done
if ! xdpyinfo >/dev/null 2>&1; then
  say "FATAL: the display never came up"; cat /work/xvfb.log; exit 5
fi
say "display ready; renderer: $(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/ {print $2}' | head -1)"

# ------------------------------------------------------------------ 5. record from the start
mkdir -p "$(dirname "${OUT}")"
say "recording to ${OUT} for ${SECONDS_TO_RECORD}s"
ffmpeg -loglevel error -y -f x11grab -framerate 24 -video_size "${WIDTH}x${HEIGHT}" \
  -i "${DISPLAY_NUM}" -t "${SECONDS_TO_RECORD}" \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -movflags +faststart \
  "${OUT}" > /work/ffmpeg.log 2>&1 &
FFMPEG_PID=$!

# ------------------------------------------------------------------ 6. the game
say "launching the engine"
# The client wants the data path on the command line as well as in the config.
"${CLIENT}" --data="${DATA_DIR}" --no-grab > "${LOG}" 2>&1 &
GAME_PID=$!

# ------------------------------------------------------------------ 7. drive it
type_text() { xdotool type --delay 60 -- "$1"; }
press()     { xdotool key --clearmodifiers "$1"; }

if [[ "${SKIP_STARTUP}" -eq 0 ]]; then
  say "waiting for the game to reach the main menu"
  sleep 25
  # The console is the honest way in without a save file: teleport straight into a cell.
  say "console: coc \"${CELL}\""
  press "grave"
  sleep 2
  type_text "coc \"${CELL}\""
  sleep 1
  press "Return"
  sleep 12
fi

say "walking and looking around so the footage has motion"
xdotool mousemove_relative -- 200 0
xdotool keydown w
sleep 4
xdotool mousemove_relative -- 260 0
sleep 3
xdotool keyup w
xdotool keydown a
sleep 2
xdotool keyup a
xdotool mousemove_relative -- -300 40
sleep 2

# ------------------------------------------------------------------ 8. wrap up
say "waiting for the recorder to finish"
wait "${FFMPEG_PID}" 2>/dev/null
kill "${GAME_PID}" 2>/dev/null
kill "${XVFB_PID}" 2>/dev/null

if [[ -s "${OUT}" ]]; then
  say "wrote $(du -h "${OUT}" | cut -f1) to ${OUT}"
else
  say "no video was produced — see ${LOG}"
  tail -20 "${LOG}" 2>/dev/null
  exit 6
fi
