#!/usr/bin/env bash
# Run Morrowind in a container and record it. Host side of kingdom/game/capture.sh.
#
#   bash kingdom/game/run-game.sh --help
#   bash kingdom/game/run-game.sh --cell "Seyda Neen" --seconds 30
#   bash kingdom/game/run-game.sh --mode mp --server 100.102.189.126 --name liam --password 'XXXXX-...'
#
# It finds (and unpacks, once) the TES3MP Linux build, checks the game data is in place, and runs the
# capture harness inside the container with only the mounts it needs: the engine read-only, the game
# data read-only, the world directory read-write (that is where the MCP files live), and the media
# directory for the finished video.

set -euo pipefail

KINGDOM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="${KOS_ENGINE_DIR:-/home/liamb/kos-world/engine}"
DATA_DIR="${KOS_DATA_DIR:-/home/liamb/morrowind-data}"
WORLD_DIR="${KOS_WORLD_DIR:-/home/liamb/kos-world}"
MEDIA_DIR="${KOS_MEDIA_DIR:-/home/liamb/Media}"
IMAGE="${KOS_GAME_IMAGE:-kos-game}"

MODE="single"; SECS=30; CELL="Seyda Neen"; OUT=""; SERVER="127.0.0.1"; PORT="25565"
NAME="worldsmith"; PASSWORD=""; W=1280; H=720; SKIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --seconds) SECS="$2"; shift 2 ;;
    --cell) CELL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --server) SERVER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --width) W="$2"; shift 2 ;;
    --height) H="$2"; shift 2 ;;
    --skip-startup) SKIP=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- the engine
if ! ls "${ENGINE_DIR}"/*/tes3mp >/dev/null 2>&1 && ! ls "${ENGINE_DIR}"/tes3mp >/dev/null 2>&1; then
  say "unpacking the TES3MP Linux build into ${ENGINE_DIR}"
  mkdir -p "${ENGINE_DIR}"
  for tarball in "${ENGINE_DIR}"/*.tar.gz; do
    [[ -e "${tarball}" ]] || continue
    case "$(basename "${tarball}")" in
      tes3mp-server*) target="${ENGINE_DIR}/server" ;;
      *) target="${ENGINE_DIR}/client" ;;
    esac
    mkdir -p "${target}"
    tar xzf "${tarball}" -C "${target}" --strip-components=1 2>/dev/null || tar xzf "${tarball}" -C "${target}"
    say "  $(basename "${tarball}") -> ${target}"
  done
fi

CLIENT_DIR=""
for candidate in "${ENGINE_DIR}/client" "${ENGINE_DIR}"; do
  if [[ -d "${candidate}" ]] && find "${candidate}" -maxdepth 2 -type f -name 'tes3mp*' -perm -u+x | grep -q .; then
    CLIENT_DIR="${candidate}"; break
  fi
done
[[ -n "${CLIENT_DIR}" ]] || die "no TES3MP client found under ${ENGINE_DIR} — download the Linux release into it"

# ---------------------------------------------------------------- the game data
if ! find "${DATA_DIR}" -maxdepth 2 -iname 'Morrowind.esm' 2>/dev/null | grep -q .; then
  say ""
  say "Morrowind's data files are not in ${DATA_DIR} yet."
  say "The engine cannot start without them, and there is nothing to record. Put these there:"
  say "    Morrowind.esm  Tribunal.esm  Bloodmoon.esm"
  say "    Morrowind.bsa  Tribunal.bsa  Bloodmoon.bsa"
  say "    (plus the Music/ and Sound/ folders if you have them)"
  say ""
  say "From a Steam install they live in: steamapps/common/Morrowind/Data Files/"
  exit 4
fi

# ---------------------------------------------------------------- the image
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  say "building the runtime image (${IMAGE}) — first time only, a few minutes"
  docker build -t "${IMAGE}" "${KINGDOM}/game"
fi

# ---------------------------------------------------------------- record
[[ -n "${OUT}" ]] || OUT="${MEDIA_DIR}/videos/morrowind-${MODE}-$(date -u +%Y%m%d-%H%M%S).mp4"
mkdir -p "$(dirname "${OUT}")" "${WORLD_DIR}/work"
chmod +x "${KINGDOM}/game/capture.sh"

say "recording ${SECS}s of ${MODE} mode from ${CELL}"

docker run --rm \
  --name kos-game-run \
  --device /dev/dri \
  -v "${CLIENT_DIR}:/game:ro" \
  -v "${DATA_DIR}:/morrowind:ro" \
  -v "${WORLD_DIR}:/kos-world:rw" \
  -v "${MEDIA_DIR}:/media:rw" \
  -v "${KINGDOM}/game:/capture:ro" \
  -v "${WORLD_DIR}/work:/work:rw" \
  "${IMAGE}" \
  /capture/capture.sh \
    --mode "${MODE}" --seconds "${SECS}" --out "/media/videos/$(basename "${OUT}")" \
    --cell "${CELL}" --server "${SERVER}" --port "${PORT}" --name "${NAME}" \
    ${PASSWORD:+--password "${PASSWORD}"} \
    --width "${W}" --height "${H}" \
    $( [[ "${SKIP}" -eq 1 ]] && echo --skip-startup )

if [[ -s "${OUT}" ]]; then
  say ""
  say "video: https://beelink.tail96c9e1.ts.net/media/videos/$(basename "${OUT}")"
  say "log:   ${WORLD_DIR}/work/capture.log"
else
  die "no video produced; see ${WORLD_DIR}/work/capture.log"
fi
