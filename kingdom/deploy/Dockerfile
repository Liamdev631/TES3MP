# Kingdom of Science — the game MCP surface, in a capability-free box on the tailnet.
#
# This image runs the kos_mcp.py MCP server *and* a Tailscale node in USERSPACE mode, so the
# whole thing needs no --privileged, no --cap-add=NET_ADMIN and no /dev/net/tun — nothing this
# host (no root) could have granted. The node joins the tailnet as its OWN device, separate from
# beelink, and publishes only the game surface.
#
# Build:  docker build -t kos-node:local /home/liamb/projects/TES3MP/kingdom/deploy
# Run:    see docker-compose.yml, or README.md for the exact `docker run`

FROM python:3.11-slim

# The Tailscale daemon and CLI are static Go binaries — copied straight out of the official
# image so the node version tracks upstream exactly, without inheriting its Alpine userland.
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscale  /usr/local/bin/tailscale

# The same MCP Python SDK the project venv uses (/home/liamb/projects/TES3MP/kingdom/.venv is
# mcp 2.3.0, class mcp.server.mcpserver.MCPServer). Pinned to the same major version.
RUN pip install --no-cache-dir "mcp==2.3.0"

RUN mkdir -p /var/lib/tailscale /var/run/tailscale /kos-world

WORKDIR /app
COPY entrypoint.sh /usr/local/bin/kos-entrypoint
COPY mcp_http.py    /app/mcp_http.py
RUN chmod 0755 /usr/local/bin/kos-entrypoint

# Userspace networking is what makes this capability-free.
ENV TS_USERSPACE=true \
    KOS_WORLD_DIR=/kos-world \
    KOS_MCP_HOST=127.0.0.1 \
    KOS_MCP_PORT=8000

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/kos-entrypoint"]
