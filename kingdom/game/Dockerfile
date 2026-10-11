# Kingdom of Science — the game, in a box.
#
# Everything Morrowind needs, and nothing from the host: the engine binaries and the game data are
# mounted at run time rather than baked in, so the image is nothing but a runtime. Based on 22.04
# because the TES3MP 0.8.1 Linux builds were made against that era of glibc and its libraries.
#
# Build:  docker build -t kos-game kingdom/game
# Run:    bash kingdom/game/run-game.sh --help

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# The dependency list is the repo's own (CI/install_debian_deps.sh), plus what rendering a window and
# recording it needs. The -dev packages are used as a convenient way to pull in exactly the runtime
# libraries the binaries link against.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
        make cmake ccache git pkg-config \
        libboost-filesystem-dev libboost-program-options-dev libboost-system-dev \
        libboost-iostreams-dev \
        libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libswresample-dev \
        libsdl2-dev libqt5opengl5-dev libopenal-dev libunshield-dev libtinyxml-dev \
        libbullet-dev liblz4-dev libpng-dev libjpeg-dev \
        libmygui-dev libopenscenegraph-dev \
        xvfb xdotool x11-utils xauth ffmpeg \
        mesa-utils libgl1-mesa-dri libglx-mesa0 libglu1-mesa \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# A place for the game, the data and the output; all three are mounts in practice.
RUN mkdir -p /game /morrowind /kos-world /media /capture /work

WORKDIR /work

# The capture harness is mounted at run time; this is only a default.
CMD ["/bin/bash"]
