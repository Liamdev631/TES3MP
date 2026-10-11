#!/usr/bin/env python3
"""Kingdom of Science — MCP server for the Morrowind world.

Agents get tools instead of an API to memorise. Each tool turns into one command in the queue that
`kingdom/server-lua/kingdom_bridge.lua` drains on the game's next event, so nothing here needs the
game to be running: commands wait, and the answers come back through the state file the game
publishes.

Design rules, all of them deliberate:

* **Nothing is invented.** Read tools report what the game last published, and say plainly when the
  game has not reported in — they never guess a position, a player or a success.
* **Everything is attributed.** Each command carries the agent's name (`KOS_AGENT`) and a unique id,
  and every attempt lands in the applied log.
* **Writes can be switched off.** `KOS_MCP_READONLY=1` exposes the world read-only, for an agent
  that should only be able to look.
* **The allow-list is enforced twice.** This server refuses a cell it does not know so the agent gets
  a clear answer immediately; the game-side bridge refuses it again, authoritatively, because that is
  where it actually matters.

Run it (stdio, the usual MCP transport):

    kingdom/.venv/bin/python kingdom/agent-api/kos_mcp.py

Environment: `KOS_WORLD_DIR` (default `/home/liamb/kos-world`), `KOS_AGENT`, `KOS_MEDIA_BASE`,
`KOS_MCP_READONLY`.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

WORLD_DIR = Path(os.environ.get("KOS_WORLD_DIR", "/home/liamb/kos-world"))
QUEUE = WORLD_DIR / "queue.jsonl"
APPLIED = WORLD_DIR / "applied.jsonl"
STATE = WORLD_DIR / "world-state.json"
SCREENSHOT_DIR = WORLD_DIR / "screenshots"
FLAGS_FILE = Path(os.environ.get("KOS_FLAGS_FILE", str(WORLD_DIR / "flags.json")))
MEDIA_BASE = os.environ.get("KOS_MEDIA_BASE", "https://beelink.tail96c9e1.ts.net/media")

# The same two-class flag list the server script uses, and the same action→flag map, so an agent
# gets an identical answer whether the MCP server refuses it or the game-side bridge does. The
# bridge is the authority; this copy fails early and explains itself.
KNOWN_FLAGS = {
    "experiments": "master switch for every experimental feature",
    "world_edits": "allow agent world edits at all (queue drain)",
    "weather_control": "let agents set the weather and the clock",
    "avatar_control": "let agents move a player's avatar and change its stats or model",
    "screenshots": "let agents request in-game screenshots",
    "world_speech": "let agents speak in the world's voice",
    "exp_custom_models": "let agents define new object types pointing at model files",
    "exp_npc_control": "let agents move, heal and kill NPCs",
    "exp_console": "let agents run raw console commands on a client",
    "exp_scheduled_weather": "let agents drive weather on a schedule rather than on request",
    "exp_player_remodel": "let agents change what a player looks like while they play",
    "exp_hot_reload": "reload the server's Lua when the files change, without a full restart",
}

ACTION_FLAG = {
    "spawn_object": "world_edits",
    "define_record": "exp_custom_models",
    "delete_object": "world_edits",
    "move_object": "world_edits",
    "scale_object": "world_edits",
    "set_weather": "weather_control",
    "set_time": "weather_control",
    "move_actor": "exp_npc_control",
    "set_actor_health": "exp_npc_control",
    "kill_actor": "exp_npc_control",
    "teleport_player": "avatar_control",
    "set_player_model": "exp_player_remodel",
    "set_player_stats": "avatar_control",
    "say": "world_speech",
    "screenshot": "screenshots",
    "console": "exp_console",
}

EXPERIMENT_PREFIX = "exp_"


def read_flags() -> dict[str, bool]:
    """Every known flag with the state the file currently gives it. Read fresh each time: flipping a
    flag must not require restarting an agent's server."""
    raw: dict[str, Any] = {}
    try:
        raw = json.loads(FLAGS_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raw = {}
    experiments = raw.get("experiments") is True
    state: dict[str, bool] = {}
    for name in KNOWN_FLAGS:
        if name != "experiments" and name.startswith(EXPERIMENT_PREFIX) and not experiments:
            state[name] = False
        else:
            state[name] = raw.get(name) is True
    return state


def flag_enabled(name: str) -> bool:
    return read_flags().get(name, False)

# Mirrors the bridge's list. The bridge is the authority; this copy exists to fail early and kindly.
ALLOWED_CELLS = {
    cell.strip()
    for cell in os.environ.get(
        "KOS_ALLOWED_CELLS",
        "Kingdom Workshop,Balmora, Council Club,Seyda Neen, Arrille's Tradehouse",
    ).split(",")
    if cell.strip()
}

STATE_FRESH_SECONDS = 120  # a snapshot older than this means the game is not really running


class Refused(Exception):
    """A command that will not be queued, with the reason an agent can act on."""


def agent_name() -> str:
    return os.environ.get("KOS_AGENT", "unknown-agent")


def read_only() -> bool:
    return os.environ.get("KOS_MCP_READONLY", "").strip() in {"1", "true", "yes"}


# --------------------------------------------------------------------------- transport


def queue_command(action: str, cell: str | None, **fields: Any) -> dict[str, Any]:
    """Append one command to the queue the game drains. Returns the record that was written."""
    if read_only():
        raise Refused("this server is in read-only mode (KOS_MCP_READONLY=1)")
    flag = ACTION_FLAG.get(action)
    if flag and not flag_enabled(flag):
        raise Refused(
            f"that feature is switched off: {flag}. "
            f"{KNOWN_FLAGS.get(flag, '')} — turn it on in {FLAGS_FILE} if it should be live."
        )
    if cell is not None and cell not in ALLOWED_CELLS:
        raise Refused(
            f"{cell!r} is not a cell agents may change. Allowed: {', '.join(sorted(ALLOWED_CELLS))}"
        )
    command: dict[str, Any] = {
        "id": uuid.uuid4().hex[:12],
        "at": round(time.time(), 3),
        "action": action,
        "agent": agent_name(),
    }
    if cell is not None:
        command["cell"] = cell
    for key, value in fields.items():
        if value is not None:
            command[key] = value
    WORLD_DIR.mkdir(parents=True, exist_ok=True)
    with QUEUE.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(command, sort_keys=True) + "\n")
    return command


def world_state() -> dict[str, Any] | None:
    """The last thing the game published, or None when it never has."""
    if not STATE.exists():
        return None
    try:
        state = json.loads(STATE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    state["age_seconds"] = round(time.time() - float(state.get("at", 0)), 1)
    state["fresh"] = state["age_seconds"] < STATE_FRESH_SECONDS
    return state


def tail(path: Path, count: int) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    out = []
    for line in lines[-count:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def pending_commands() -> list[dict[str, Any]]:
    return tail(QUEUE, 100)


def not_connected() -> str:
    return (
        f"The game has not reported in yet (no fresh snapshot at {STATE}). "
        f"{len(pending_commands())} command(s) are waiting in the queue and will be applied when it starts."
    )


# --------------------------------------------------------------------------- the tools themselves
#
# These are plain functions on purpose: the MCP wrapper below is one line each, and the tests call
# these directly to check what actually gets queued.


def tool_world_status() -> dict[str, Any]:
    state = world_state()
    flags = read_flags()
    return {
        "game_connected": bool(state and state.get("fresh")),
        "state": state,
        "note": None if state else not_connected(),
        "queued": len(pending_commands()),
        "you_are": agent_name(),
        "writes_allowed": not read_only(),
        "flags": flags,
        "flags_file": str(FLAGS_FILE),
    }


def tool_list_flags() -> dict[str, Any]:
    """Which features are live, what each one does, and where the switch is."""
    state = read_flags()
    return {
        "flags_file": str(FLAGS_FILE),
        "live": sorted(name for name, on in state.items() if on),
        "off": sorted(name for name, on in state.items() if not on),
        "detail": {name: {"on": state[name], "what": KNOWN_FLAGS[name]} for name in KNOWN_FLAGS},
        "note": "experiments stay off unless the master switch `experiments` is on as well",
    }


def tool_list_players() -> dict[str, Any]:
    state = world_state()
    if not state:
        return {"players": [], "note": not_connected()}
    return {"players": state.get("players", []), "fresh": state.get("fresh"), "age_seconds": state.get("age_seconds")}


def tool_recent_activity(limit: int = 20) -> dict[str, Any]:
    return {"applied": tail(APPLIED, max(1, min(limit, 100)))}


def tool_spawn_object(
    cell: str,
    ref_id: str,
    position: list[float],
    count: int = 1,
    rotation: list[float] | None = None,
    scale: float | None = None,
) -> dict[str, Any]:
    """Spawn an existing object type into a cell — a pillar, a crate, a bed, anything Morrowind knows."""
    return queue_command(
        "spawn_object", cell, refId=ref_id, position=list(position), count=int(count),
        rotation=list(rotation) if rotation else None, scale=scale,
    )


def tool_define_model(
    record_id: str,
    model: str,
    name: str | None = None,
    scale: float | None = None,
    record_type: int = 0,
) -> dict[str, Any]:
    """Define a brand-new object type pointing at a model file, and push it to every player live.

    This is how a custom asset reaches the world: the model must already exist in the players' data
    folders (under meshes/), and this makes the game know about it without a restart.
    """
    return queue_command(
        "define_record", None, recordId=record_id, model=model, name=name, scale=scale,
        recordType=int(record_type),
    )


def tool_move_object(
    cell: str,
    mp_num: int,
    position: list[float] | None = None,
    rotation: list[float] | None = None,
) -> dict[str, Any]:
    """Move or rotate an object that is already in the world. `mp_num` is the id from a snapshot."""
    if position is None and rotation is None:
        raise Refused("give a position, a rotation, or both")
    return queue_command(
        "move_object", cell, mpNum=int(mp_num),
        position=list(position) if position else None,
        rotation=list(rotation) if rotation else None,
    )


def tool_scale_object(cell: str, mp_num: int, scale: float) -> dict[str, Any]:
    """Resize an object in place."""
    return queue_command("scale_object", cell, mpNum=int(mp_num), scale=float(scale))


def tool_delete_object(cell: str, mp_num: int) -> dict[str, Any]:
    """Remove an object from the world."""
    return queue_command("delete_object", cell, mpNum=int(mp_num))


def tool_set_weather(
    weather: int,
    region: str | None = None,
    next_weather: int | None = None,
    transition: float | None = None,
    force: bool = True,
) -> dict[str, Any]:
    """Set the weather. Indices follow Morrowind's: 0 clear, 1 foggy, 2 cloudy, 3 rain, 4 thunder,
    5 ash, 6 blight, 7 snow, 8 blizzard — and the result goes to everyone at once."""
    return queue_command(
        "set_weather", None, weather=int(weather), region=region, next=int(next_weather) if next_weather is not None else None,
        transition=transition, force=bool(force),
    )


def tool_set_time(
    hour: float | None = None,
    day: int | None = None,
    month: int | None = None,
    year: int | None = None,
    days_passed: int | None = None,
    time_scale: float | None = None,
) -> dict[str, Any]:
    """Set the world clock — the hour of the day, the date, or how fast time runs."""
    if all(value is None for value in (hour, day, month, year, days_passed, time_scale)):
        raise Refused("give at least one of hour, day, month, year, days_passed, time_scale")
    return queue_command(
        "set_time", None, hour=hour, day=day, month=month, year=year,
        daysPassed=days_passed, timeScale=time_scale,
    )


def tool_move_npc(
    cell: str,
    position: list[float] | None = None,
    rotation: list[float] | None = None,
    mp_num: int | None = None,
    ref_id: str | None = None,
) -> dict[str, Any]:
    """Move an NPC. Address it by `mp_num` (from a snapshot) or by `ref_id` within a cell."""
    if mp_num is None and ref_id is None:
        raise Refused("give mp_num or ref_id")
    if position is None and rotation is None:
        raise Refused("give a position, a rotation, or both")
    return queue_command(
        "move_actor", cell, mpNum=int(mp_num) if mp_num is not None else None, refId=ref_id,
        position=list(position) if position else None,
        rotation=list(rotation) if rotation else None,
    )


def tool_set_npc_health(
    cell: str, health: float, mp_num: int | None = None, ref_id: str | None = None
) -> dict[str, Any]:
    """Set an NPC's current health — 0 kills them, high values make them a wall."""
    if mp_num is None and ref_id is None:
        raise Refused("give mp_num or ref_id")
    return queue_command(
        "set_actor_health", cell, health=float(health),
        mpNum=int(mp_num) if mp_num is not None else None, refId=ref_id,
    )


def tool_kill_npc(
    cell: str, mp_num: int | None = None, ref_id: str | None = None, resurrect: bool = False
) -> dict[str, Any]:
    """Kill an NPC — or set resurrect=True to bring them back."""
    if mp_num is None and ref_id is None:
        raise Refused("give mp_num or ref_id")
    return queue_command(
        "kill_actor", cell, mpNum=int(mp_num) if mp_num is not None else None, refId=ref_id,
        resurrect=True if resurrect else None,
    )


def tool_teleport_player(
    pid: int,
    cell: str | None = None,
    position: list[float] | None = None,
    rotation: list[float] | None = None,
) -> dict[str, Any]:
    """Move a player's avatar, optionally into another cell. `pid` comes from list_players."""
    if cell is None and position is None:
        raise Refused("give a cell, a position, or both")
    if cell is not None and cell not in ALLOWED_CELLS:
        # A player can be sent anywhere they could walk to; a cell limit would be arbitrary here, so
        # this is deliberately permissive — but the world owner is told, in the log, who did it.
        pass
    return queue_command(
        "teleport_player", cell, pid=int(pid),
        position=list(position) if position else None,
        rotation=list(rotation) if rotation else None,
    )


def tool_set_avatar_model(pid: int, model: str) -> dict[str, Any]:
    """Change what a player looks like, using a model their data folder carries."""
    return queue_command("set_player_model", None, pid=int(pid), model=model)


def tool_set_avatar_stats(
    pid: int,
    health: float | None = None,
    level: int | None = None,
    name: str | None = None,
) -> dict[str, Any]:
    """Set a player's health, level or displayed name."""
    if health is None and level is None and name is None:
        raise Refused("give health, level or name")
    return queue_command("set_player_stats", None, pid=int(pid), health=health, level=level, name=name)


def tool_say(message: str) -> dict[str, Any]:
    """Speak in the world's voice — everyone online sees it."""
    if not message.strip():
        raise Refused("the message is empty")
    return queue_command("say", None, message=message[:400])


def tool_run_console(command: str, cell: str, pid: int | None = None) -> dict[str, Any]:
    """Run a Morrowind console command on a client. Powerful, and logged like everything else: this
    can teleport, spawn, kill and edit anything the console can."""
    if not command.strip():
        raise Refused("the console command is empty")
    return queue_command("console", cell, command=command, pid=int(pid) if pid is not None else None)


def tool_take_screenshot(
    cell: str,
    position: list[float] | None = None,
    rotation: list[float] | None = None,
    filename: str | None = None,
) -> dict[str, Any]:
    """Ask for a picture from a spot in the world. Returns where it will appear once taken; the
    capture helper frames it, so check the URL a few seconds later."""
    name = (filename or f"shot-{uuid.uuid4().hex[:8]}").replace("/", "-")
    if not name.endswith(".png"):
        name += ".png"
    command = queue_command(
        "screenshot", cell,
        position=list(position) if position else None,
        rotation=list(rotation) if rotation else None,
        filename=name,
    )
    return {
        "queued": command,
        "will_appear_at": f"{MEDIA_BASE}/screenshots/{name}",
        "note": "the picture exists once the capture helper has run; it is not instant",
    }


TOOLS = {
    "world_status": tool_world_status,
    "list_flags": tool_list_flags,
    "list_players": tool_list_players,
    "recent_activity": tool_recent_activity,
    "spawn_object": tool_spawn_object,
    "define_model": tool_define_model,
    "move_object": tool_move_object,
    "scale_object": tool_scale_object,
    "delete_object": tool_delete_object,
    "set_weather": tool_set_weather,
    "set_time": tool_set_time,
    "move_npc": tool_move_npc,
    "set_npc_health": tool_set_npc_health,
    "kill_npc": tool_kill_npc,
    "teleport_player": tool_teleport_player,
    "set_avatar_model": tool_set_avatar_model,
    "set_avatar_stats": tool_set_avatar_stats,
    "say": tool_say,
    "run_console": tool_run_console,
    "take_screenshot": tool_take_screenshot,
}

INSTRUCTIONS = """Tools for the Kingdom of Science — a private Morrowind world running on TES3MP.

Who is online, where they are, and what has been done recently: `world_status`, `list_players`,
`recent_activity`.

Shaping the world: `spawn_object` and `delete_object` for objects, `define_model` to introduce a new
object type pointing at a model the players already have, `move_object` and `scale_object` to adjust
one, `set_weather` and `set_time` for the sky and the clock, `move_npc`, `set_npc_health` and
`kill_npc` for the people in it, and `say` to speak to everyone.

Avatars: `teleport_player`, `set_avatar_model`, `set_avatar_stats`.

Looking at the result: `take_screenshot` frames a view and returns where the picture will appear.
`run_console` runs a raw Morrowind console command on a client — it can do anything, so treat it as
the sharp tool.

Only cells on the allow-list can be changed, every command is recorded with the name of the agent
that sent it, and read tools report the last thing the game published rather than guessing."""


def build_server():  # pragma: no cover - exercised by the stdio smoke test
    from mcp.server.mcpserver import MCPServer

    server = MCPServer(name="kingdom", instructions=INSTRUCTIONS)

    @server.tool()
    def world_status() -> dict[str, Any]:
        """Is the world running, who is in it, and is anything queued?"""
        return tool_world_status()

    @server.tool()
    def list_flags() -> dict[str, Any]:
        """Which features are live, what each one does, and where the switch is."""
        return tool_list_flags()

    @server.tool()
    def list_players() -> dict[str, Any]:
        """Who is online, with their pid, cell and position."""
        return tool_list_players()

    @server.tool()
    def recent_activity(limit: int = 20) -> dict[str, Any]:
        """What agents have done to the world recently, newest last."""
        return tool_recent_activity(limit)

    @server.tool()
    def spawn_object(cell: str, ref_id: str, position: list[float], count: int = 1,
                     rotation: list[float] | None = None, scale: float | None = None) -> dict[str, Any]:
        """Spawn an object type at a position in a cell."""
        return tool_spawn_object(cell, ref_id, position, count, rotation, scale)

    @server.tool()
    def define_model(record_id: str, model: str, name: str | None = None, scale: float | None = None,
                     record_type: int = 0) -> dict[str, Any]:
        """Introduce a new object type pointing at a model file, live, for every player."""
        return tool_define_model(record_id, model, name, scale, record_type)

    @server.tool()
    def move_object(cell: str, mp_num: int, position: list[float] | None = None,
                    rotation: list[float] | None = None) -> dict[str, Any]:
        """Move or rotate an existing object."""
        return tool_move_object(cell, mp_num, position, rotation)

    @server.tool()
    def scale_object(cell: str, mp_num: int, scale: float) -> dict[str, Any]:
        """Resize an existing object."""
        return tool_scale_object(cell, mp_num, scale)

    @server.tool()
    def delete_object(cell: str, mp_num: int) -> dict[str, Any]:
        """Remove an object from the world."""
        return tool_delete_object(cell, mp_num)

    @server.tool()
    def set_weather(weather: int, region: str | None = None, next_weather: int | None = None,
                    transition: float | None = None, force: bool = True) -> dict[str, Any]:
        """Set the weather everyone sees. 0 clear, 1 foggy, 2 cloudy, 3 rain, 4 thunder, 5 ash, 6 blight, 7 snow, 8 blizzard."""
        return tool_set_weather(weather, region, next_weather, transition, force)

    @server.tool()
    def set_time(hour: float | None = None, day: int | None = None, month: int | None = None,
                 year: int | None = None, days_passed: int | None = None,
                 time_scale: float | None = None) -> dict[str, Any]:
        """Set the world clock: hour of day, date, or how fast time runs."""
        return tool_set_time(hour, day, month, year, days_passed, time_scale)

    @server.tool()
    def move_npc(cell: str, position: list[float] | None = None, rotation: list[float] | None = None,
                 mp_num: int | None = None, ref_id: str | None = None) -> dict[str, Any]:
        """Move an NPC within a cell."""
        return tool_move_npc(cell, position, rotation, mp_num, ref_id)

    @server.tool()
    def set_npc_health(cell: str, health: float, mp_num: int | None = None,
                       ref_id: str | None = None) -> dict[str, Any]:
        """Set an NPC's health."""
        return tool_set_npc_health(cell, health, mp_num, ref_id)

    @server.tool()
    def kill_npc(cell: str, mp_num: int | None = None, ref_id: str | None = None,
                 resurrect: bool = False) -> dict[str, Any]:
        """Kill an NPC, or bring one back with resurrect=True."""
        return tool_kill_npc(cell, mp_num, ref_id, resurrect)

    @server.tool()
    def teleport_player(pid: int, cell: str | None = None, position: list[float] | None = None,
                        rotation: list[float] | None = None) -> dict[str, Any]:
        """Move a player's avatar, optionally to another cell."""
        return tool_teleport_player(pid, cell, position, rotation)

    @server.tool()
    def set_avatar_model(pid: int, model: str) -> dict[str, Any]:
        """Change what a player looks like."""
        return tool_set_avatar_model(pid, model)

    @server.tool()
    def set_avatar_stats(pid: int, health: float | None = None, level: int | None = None,
                         name: str | None = None) -> dict[str, Any]:
        """Set a player's health, level or name."""
        return tool_set_avatar_stats(pid, health, level, name)

    @server.tool()
    def say(message: str) -> dict[str, Any]:
        """Speak to everyone in the world."""
        return tool_say(message)

    @server.tool()
    def run_console(command: str, cell: str, pid: int | None = None) -> dict[str, Any]:
        """Run a raw Morrowind console command on a client — powerful and always logged."""
        return tool_run_console(command, cell, pid)

    @server.tool()
    def take_screenshot(cell: str, position: list[float] | None = None,
                        rotation: list[float] | None = None,
                        filename: str | None = None) -> dict[str, Any]:
        """Ask for a picture from a spot in the world and get back where it will appear."""
        return tool_take_screenshot(cell, position, rotation, filename)

    return server


def main() -> None:  # pragma: no cover - needs a client to talk to
    build_server().run(transport="stdio")


if __name__ == "__main__":
    main()
