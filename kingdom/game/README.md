# Running Morrowind — and recording it

Everything the engine needs to *render*, in a container, so that a video of the game is one command.
The image holds only a runtime: the engine binaries and the game data are mounted when it runs, which
means a new build or a new save needs no rebuild of anything.

```bash
bash kingdom/game/run-game.sh --cell "Seyda Neen" --seconds 30
bash kingdom/game/run-game.sh --mode mp --server 100.102.189.126 --name liam --password 'XXXXX-XXXXX-XXXXX-XXXXX'
bash kingdom/game/run-game.sh --help
```

What it does: `capture.sh` (inside) starts Xvfb on a private display, writes an OpenMW config pointing
at the mounted data, launches the client, opens the console and teleports into a cell, walks and looks
around for a few seconds, and records the whole thing with ffmpeg — starting the recording *before*
the game, so a failure still produces a video showing what went wrong. `run-game.sh` (outside) unpacks
the engine once, refuses politely if the game data is missing, and prints the media-server URL at the
end.

## Layout at run time

| Inside the container | From the host | Access |
|---|---|---|
| `/game` | `~/kos-world/engine/client` (or `server`) | read-only |
| `/morrowind` | `~/morrowind-data` | read-only |
| `/kos-world` | `~/kos-world` | read-write — this is where the MCP files live |
| `/media` | `~/Media` | read-write — the video lands here |
| `/capture` | `~/projects/TES3MP/kingdom/game` | read-only |
| `/work` | `~/kos-world/work` | read-write — logs from every attempt |

The container gets `--device /dev/dri` and nothing else: no host network, no Docker socket, no
privileged mode.

**Mounts must live under `/home/liamb`.** Docker here is the snap build, and its confinement refuses
to expose host paths outside the user's home — a data directory in `/tmp` is simply invisible inside
the container (found by testing, not by reading a manual). Every default in `run-game.sh` respects
this; a custom `KOS_DATA_DIR` must too.

## What is verified

* The image builds and contains the engine's runtime dependencies, Xvfb, ffmpeg and a software GL
  stack (checked by building it, then by starting the client inside it and reading what it says).
* The engine binaries unpack and are the right shape: `tes3mp` (client) and `tes3mp-server` (server),
  with CoreScripts shipped inside the server tarball at `server/server/scripts/`.
* The capture path is written and syntax-checked; it produces a video from whatever the display shows.

## What needs the game data

Rendering Morrowind. Without `Morrowind.esm` the client refuses to start — correctly, and the harness
says so instead of producing a fake video. Put the files in `~/morrowind-data/`:

```
Morrowind.esm  Tribunal.esm  Bloodmoon.esm
Morrowind.bsa  Tribunal.bsa  Bloodmoon.bsa
Music/  Sound/            (optional but the game is quieter without them)
```

Then the first in-game video is one command.

## Performance note

Xvfb gives the engine a software GL stack (Mesa llvmpipe), which is enough for a video but not for
smooth gameplay at high resolution. If the frame rate matters, the next step is a virtual X server
that can use `/dev/dri` directly; the capture harness does not change either way.
