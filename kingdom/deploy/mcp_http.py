#!/usr/bin/env python3
"""Serve the Kingdom of Science MCP server over streamable HTTP — loopback only.

The network surface that Robby's agent may reach is published by ``tailscale serve`` in
``entrypoint.sh``; that proxy forwards tailnet traffic to this loopback port. Nothing here ever
binds ``0.0.0.0``, so the only way in from the tailnet is the one route ``tailscale serve``
exposes.

The tool functions and their behaviour are exactly those of the mounted ``kos_mcp.py`` (twenty
tools: world_status, list_flags, list_players, recent_activity, spawn_object, define_model,
move_object, scale_object, delete_object, set_weather, set_time, move_npc, set_npc_health,
kill_npc, teleport_player, set_avatar_model, set_avatar_stats, say, run_console, take_screenshot).
"""

from __future__ import annotations

import importlib.util
import os

SCRIPT = os.environ.get("KOS_MCP_SCRIPT", "/app/kos_mcp.py")
HOST = os.environ.get("KOS_MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("KOS_MCP_PORT", "8000"))


def load_server():
    """Import the mounted, read-only kos_mcp.py and build its MCP server object."""
    spec = importlib.util.spec_from_file_location("kos_mcp", SCRIPT)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load MCP server script: {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.build_server()


def main() -> None:
    server = load_server()
    # stateless_http: one shared surface, no per-session bookkeeping left behind for a peer.
    server.run(
        transport="streamable-http",
        host=HOST,
        port=PORT,
        stateless_http=True,
        streamable_http_path="/mcp",
    )


if __name__ == "__main__":
    main()
