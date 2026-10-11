#!/bin/sh
# Kingdom of Science — container entrypoint.
#
# Starts tailscaled in USERSPACE mode (no /dev/net/tun, no NET_ADMIN), optionally joins the
# tailnet as this container's own device, publishes ONLY the game surface, then runs the MCP
# server. If TS_AUTHKEY is absent the daemon still comes up, so the box is inspectable — it just
# is not joined ("Logged out").
set -eu

SOCK=/var/run/tailscale/tailscaled.sock
STATE=/var/lib/tailscale
mkdir -p "$STATE" /var/run/tailscale

echo "[kos-node] starting tailscaled (userspace networking — capability-free)"
tailscaled \
    --tun=userspace-networking \
    --socket="$SOCK" \
    --statedir="$STATE" \
    --port=41641 &

# Wait for the daemon's control socket.
i=0
while [ ! -S "$SOCK" ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 1
done

# shellcheck disable=SC2086
if [ -n "${TS_AUTHKEY:-}" ]; then
    echo "[kos-node] joining tailnet as its own device (hostname: ${TS_HOSTNAME:-kos-node})"
    tailscale --socket="$SOCK" up \
        --authkey="$TS_AUTHKEY" \
        --hostname="${TS_HOSTNAME:-kos-node}" \
        ${TS_EXTRA_ARGS:-}
    tailscale --socket="$SOCK" status | head -20 || true
    # Publish ONLY the game surface, on this node's own tailnet name.
    # Userspace mode has no kernel tailscale0, so `tailscale serve` is the sole ingress.
    tailscale --socket="$SOCK" serve --bg --https=443 http://127.0.0.1:8000 || true
    echo "[kos-node] game surface is live at https://${TS_HOSTNAME:-kos-node}.<tailnet>.ts.net/"
else
    echo "[kos-node] TS_AUTHKEY not set — daemon up but NOT joined. See README.md."
    tailscale --socket="$SOCK" status 2>&1 || true
fi

echo "[kos-node] starting game MCP surface on ${KOS_MCP_HOST:-127.0.0.1}:${KOS_MCP_PORT:-8000}"
exec python3 /app/mcp_http.py
