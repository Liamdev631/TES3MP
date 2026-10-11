#!/usr/bin/env python3
"""Tests for the Kingdom MCP server.

Run with the project's venv (it has the MCP SDK):

    kingdom/.venv/bin/python -m unittest discover -s kingdom/agent-api -v

Nothing here needs the game: the tools' job is to write well-formed commands and to report the truth
about what the game last said, and both of those are checkable on their own.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# The module reads its paths at import time, so point it somewhere harmless first.
_TMP_ROOT = tempfile.mkdtemp(prefix="kos-mcp-tests-")
os.environ["KOS_WORLD_DIR"] = _TMP_ROOT
os.environ["KOS_AGENT"] = "worldsmith"
os.environ.pop("KOS_MCP_READONLY", None)

import kos_mcp  # noqa: E402


BASELINE_FLAGS = {
    "experiments": False,
    "world_edits": True,
    "weather_control": True,
    "avatar_control": True,
    "screenshots": True,
    "world_speech": True,
    "exp_custom_models": False,
    "exp_npc_control": False,
    "exp_console": False,
}


class McpCase(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="kos-world-"))
        kos_mcp.WORLD_DIR = self.dir
        kos_mcp.QUEUE = self.dir / "queue.jsonl"
        kos_mcp.APPLIED = self.dir / "applied.jsonl"
        kos_mcp.STATE = self.dir / "world-state.json"
        kos_mcp.FLAGS_FILE = self.dir / "flags.json"
        os.environ.pop("KOS_MCP_READONLY", None)
        os.environ["KOS_AGENT"] = "worldsmith"
        self.write_flags(BASELINE_FLAGS)

    def write_flags(self, flags: dict) -> None:
        kos_mcp.FLAGS_FILE.write_text(json.dumps(flags), encoding="utf-8")

    def queued(self) -> list[dict]:
        if not kos_mcp.QUEUE.exists():
            return []
        return [json.loads(line) for line in kos_mcp.QUEUE.read_text(encoding="utf-8").splitlines() if line]

    def write_state(self, age: float = 0.0, players=None) -> None:
        kos_mcp.STATE.write_text(
            json.dumps({"at": time.time() - age, "players": players or [], "queued": 0}),
            encoding="utf-8",
        )


class TestQueueing(McpCase):
    def test_spawn_object_queues_one_well_formed_command(self) -> None:
        result = kos_mcp.tool_spawn_object("Kingdom Workshop", "kingdom_pillar", [1, 2, 3], count=2)
        queued = self.queued()
        self.assertEqual(len(queued), 1)
        self.assertEqual(queued[0]["action"], "spawn_object")
        self.assertEqual(queued[0]["cell"], "Kingdom Workshop")
        self.assertEqual(queued[0]["refId"], "kingdom_pillar")
        self.assertEqual(queued[0]["position"], [1, 2, 3])
        self.assertEqual(queued[0]["count"], 2)
        self.assertEqual(queued[0]["agent"], "worldsmith")
        self.assertEqual(queued[0]["id"], result["id"])

    def test_two_calls_get_different_ids(self) -> None:
        first = kos_mcp.tool_scale_object("Kingdom Workshop", 1, 2)
        second = kos_mcp.tool_scale_object("Kingdom Workshop", 1, 2)
        self.assertNotEqual(first["id"], second["id"], "ids must not repeat")

    def test_optional_fields_are_left_out_rather_than_nulled(self) -> None:
        kos_mcp.tool_spawn_object("Kingdom Workshop", "crate", [0, 0, 0])
        self.assertNotIn("rotation", self.queued()[0], "absent optionals stay absent")
        self.assertNotIn("scale", self.queued()[0])

    def test_a_cell_outside_the_allow_list_is_refused_before_queueing(self) -> None:
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_spawn_object("Vivec, Palace of Vivec", "crate", [0, 0, 0])
        self.assertEqual(self.queued(), [], "nothing was written")

    def test_say_carries_the_message_and_truncates_absurd_ones(self) -> None:
        kos_mcp.tool_say("hello")
        self.assertEqual(self.queued()[0]["message"], "hello")
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_say("   ")

    def test_arguments_that_make_no_sense_are_refused(self) -> None:
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_move_object("Kingdom Workshop", 3)          # no position, no rotation
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_set_time()                                   # nothing to set
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_kill_npc("Kingdom Workshop")                 # no target
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_set_avatar_stats(1)                           # nothing to set

    def test_define_model_carries_the_record_and_the_model_path(self) -> None:
        # custom models are an experiment: switching it on is part of the test
        self.write_flags({**BASELINE_FLAGS, "experiments": True, "exp_custom_models": True})
        kos_mcp.tool_define_model("kingdom_sprite", "meshes/kos/sprite.nif", name="Sprite")
        queued = self.queued()[0]
        self.assertEqual(queued["action"], "define_record")
        self.assertEqual(queued["recordId"], "kingdom_sprite")
        self.assertEqual(queued["model"], "meshes/kos/sprite.nif")

    def test_screenshot_returns_where_the_picture_will_appear(self) -> None:
        result = kos_mcp.tool_take_screenshot("Kingdom Workshop", [1, 0, 1], filename="workshop.png")
        self.assertTrue(result["will_appear_at"].endswith("/screenshots/workshop.png"))
        self.assertEqual(self.queued()[0]["action"], "screenshot")
        self.assertEqual(self.queued()[0]["filename"], "workshop.png")


class TestFlags(McpCase):
    def test_an_experiment_off_by_default_is_refused_with_the_flag_named(self) -> None:
        with self.assertRaises(kos_mcp.Refused) as caught:
            kos_mcp.tool_run_console("ToggleVanityMode", "Kingdom Workshop")
        self.assertIn("exp_console", str(caught.exception))
        self.assertEqual(self.queued(), [])

    def test_master_switch_on_with_the_flag_named_makes_it_live(self) -> None:
        self.write_flags({**BASELINE_FLAGS, "experiments": True, "exp_console": True})
        kos_mcp.tool_run_console("ToggleVanityMode", "Kingdom Workshop")
        self.assertEqual(self.queued()[0]["action"], "console")

    def test_master_switch_off_beats_an_experiment_that_is_named(self) -> None:
        self.write_flags({**BASELINE_FLAGS, "experiments": False, "exp_console": True})
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_run_console("ToggleVanityMode", "Kingdom Workshop")

    def test_baseline_features_do_not_need_the_master_switch(self) -> None:
        kos_mcp.tool_spawn_object("Kingdom Workshop", "crate", [0, 0, 0])
        kos_mcp.tool_set_weather(3)
        self.assertEqual(len(self.queued()), 2)

    def test_a_missing_flags_file_means_everything_is_off(self) -> None:
        kos_mcp.FLAGS_FILE.unlink()
        self.assertEqual(kos_mcp.read_flags()["world_edits"], False)
        with self.assertRaises(kos_mcp.Refused):
            kos_mcp.tool_spawn_object("Kingdom Workshop", "crate", [0, 0, 0])

    def test_flag_state_is_reported_by_the_tools(self) -> None:
        status = kos_mcp.tool_world_status()
        self.assertTrue(status["flags"]["world_edits"])
        self.assertFalse(status["flags"]["exp_console"])

        listed = kos_mcp.tool_list_flags()
        self.assertIn("world_edits", listed["live"])
        self.assertIn("exp_console", listed["off"])
        self.assertIn("master switch", listed["note"])

    def test_read_only_mode_blocks_every_write(self) -> None:
        os.environ["KOS_MCP_READONLY"] = "1"
        try:
            with self.assertRaises(kos_mcp.Refused):
                kos_mcp.tool_spawn_object("Kingdom Workshop", "crate", [0, 0, 0])
            self.assertEqual(self.queued(), [])
            self.assertFalse(kos_mcp.tool_world_status()["writes_allowed"])
        finally:
            os.environ.pop("KOS_MCP_READONLY", None)


class TestReading(McpCase):
    def test_with_no_snapshot_it_says_so_instead_of_inventing_one(self) -> None:
        status = kos_mcp.tool_world_status()
        self.assertFalse(status["game_connected"])
        self.assertIn("has not reported in", status["note"])
        self.assertIsNone(status["state"])

        players = kos_mcp.tool_list_players()
        self.assertEqual(players["players"], [])
        self.assertIn("has not reported in", players["note"])

    def test_a_fresh_snapshot_is_reported_with_its_players(self) -> None:
        self.write_state(age=3, players=[{"pid": 0, "name": "liam", "cell": "Kingdom Workshop",
                                          "position": [1, 0, 2]}])
        status = kos_mcp.tool_world_status()
        self.assertTrue(status["game_connected"])
        self.assertIsNone(status["note"])
        players = kos_mcp.tool_list_players()["players"]
        self.assertEqual(players[0]["name"], "liam")

    def test_a_stale_snapshot_is_not_called_connected(self) -> None:
        self.write_state(age=9999, players=[{"pid": 0, "name": "liam"}])
        self.assertFalse(kos_mcp.tool_world_status()["game_connected"])

    def test_recent_activity_reads_what_the_game_applied(self) -> None:
        kos_mcp.APPLIED.write_text(
            json.dumps({"id": "a1", "action": "spawn_object", "agent": "worldsmith", "ok": True})
            + "\n", encoding="utf-8")
        entries = kos_mcp.tool_recent_activity(10)["applied"]
        self.assertEqual(entries[0]["action"], "spawn_object")

    def test_queued_count_is_reported(self) -> None:
        kos_mcp.tool_spawn_object("Kingdom Workshop", "crate", [0, 0, 0])
        self.assertEqual(kos_mcp.tool_world_status()["queued"], 1)


class TestMcpSurface(unittest.TestCase):
    def test_the_server_registers_every_tool(self) -> None:
        import asyncio

        server = kos_mcp.build_server()
        names = {tool.name for tool in asyncio.run(server.list_tools())}
        for expected in ("world_status", "list_flags", "spawn_object", "define_model", "set_weather",
                         "move_npc", "kill_npc", "teleport_player", "set_avatar_model", "say",
                         "run_console", "take_screenshot"):
            self.assertIn(expected, names, f"{expected} is not exposed over MCP")
        self.assertGreaterEqual(len(names), 19, "the whole toolset should be reachable")


if __name__ == "__main__":
    unittest.main(verbosity=2)
