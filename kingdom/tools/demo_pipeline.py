#!/usr/bin/env python3
"""Record a real demo of the agent pipeline and render it as a video.

Nothing in here is staged output: every frame comes from a command that actually ran — the flag CLI,
the MCP tool being refused and then accepted, the bridge turning that command into engine calls under
the Lua 5.1 the game embeds, and the update script's dry run.

    kingdom/.venv/bin/python kingdom/tools/demo_pipeline.py [--out DIR]

Renders frames with PIL and encodes with ffmpeg. The honest caveat, printed on the title card: the
game itself is not running yet (Morrowind's data files are not on this box), so what you are watching
is the machinery around it, exercised for real.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[2]
KINGDOM = REPO / "kingdom"
LUA = KINGDOM / "tools" / "lua-5.1" / "bin" / "lua"
VENV_PY = KINGDOM / ".venv" / "bin" / "python"

W, H = 1280, 720
BG = (11, 15, 20)
BAR = (16, 22, 30)
FG = (230, 237, 243)
DIM = (139, 152, 165)
GREEN = (126, 231, 135)
CYAN = (121, 192, 255)
YELLOW = (227, 179, 65)
RED = (255, 123, 114)
MAGENTA = (210, 168, 255)
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
FPS = 24
LINE_H = 27
MAX_LINES = 20
WRAP = 74
FRAMES_PER_LINE = 5
MAX_FRAMES = 1500


def run(args: list[str], env: dict[str, str] | None = None, cwd: Path | None = None) -> str:
    result = subprocess.run(args, capture_output=True, text=True, env=env, cwd=cwd, timeout=600)
    return (result.stdout + result.stderr).rstrip()


class Script:
    """Collects the demo as coloured lines, then renders and encodes it."""

    def __init__(self) -> None:
        self.blocks: list[tuple[str, list[tuple[str, tuple[int, int, int]]]]] = []

    def block(self, title: str, body: list[tuple[str, tuple[int, int, int]]] | str) -> None:
        if isinstance(body, str):
            lines = [(line, DIM) for line in body.splitlines()]
        else:
            lines = body
        self.blocks.append((title, lines))

    def card(self, title: str, lines: list[tuple[str, tuple[int, int, int]]]) -> None:
        self.blocks.append((f"__card__{title}", lines))


def build_script(scratch: Path) -> Script:
    script = Script()
    env = dict(os.environ)
    env["KOS_WORLD_DIR"] = str(scratch)
    env["KOS_FLAGS_FILE"] = str(scratch / "flags.json")
    env["KOS_AGENT"] = "worldsmith"
    shutil.copy(KINGDOM / "flags.json", scratch / "flags.json")

    script.card(
        "The Kingdom of Science — the agent pipeline, working",
        [
            ("", FG),
            ("A private Morrowind world for Liam and Robby.", FG),
            ("", FG),
            ("What this shows: an agent asks for something," f" ", FG),
            ("the flags decide whether it is allowed, and the", FG),
            ("game-side bridge turns the request into engine", FG),
            ("calls — every step run for real, just now.", FG),
            ("", FG),
            ("The game itself is not running yet: Morrowind's", YELLOW),
            ("data files are not on this box. Everything around", YELLOW),
            ("it is built and tested, and this is that part.", YELLOW),
        ],
    )

    # ---- 1. the flags, as they ship
    out = run(["bash", str(KINGDOM / "tools" / "kos-flags.sh"), "list"], env=env)
    script.block("1. The flags as they ship: the baseline is on, every experiment is off", out)

    # ---- 2. an agent asks for a gated thing
    ask = (
        "import os; import kos_mcp as k;"
        "k.tool_run_console('ToggleVanityMode', 'Kingdom Workshop')"
    )
    refused = run([str(VENV_PY), "-c", ask], env=env, cwd=KINGDOM / "agent-api")
    script.block(
        "2. An agent asks for a console command — the flag is off, so it is refused",
        [
            ("$ agent  run_console 'ToggleVanityMode'  (Kingdom Workshop)", GREEN),
            ("", FG),
        ]
        + [(line.strip(), RED) for line in refused.splitlines() if line.strip()],
    )

    # ---- 3. flipping the flag, in the running world
    flip1 = run(["bash", str(KINGDOM / "tools" / "kos-flags.sh"), "set", "exp_console", "on"], env=env)
    flip2 = run(["bash", str(KINGDOM / "tools" / "kos-flags.sh"), "set", "experiments", "on"], env=env)
    script.block(
        "3. Flipping the switch — no restart, no reconnect; the server re-reads this per event",
        [(f"$ bash kos-flags.sh set exp_console on", GREEN)]
        + [(line, YELLOW if "note:" in line else DIM) for line in flip1.splitlines()]
        + [(f"$ bash kos-flags.sh set experiments on", GREEN)]
        + [(line, DIM) for line in flip2.splitlines()],
    )

    # ---- 4. the same ask, now allowed, landing in the queue
    allowed = run([str(VENV_PY), "-c", ask], env=env, cwd=KINGDOM / "agent-api")
    queued = (scratch / "queue.jsonl").read_text(encoding="utf-8").strip()
    script.block(
        "4. The same request, now queued with the agent's name on it",
        [
            ("$ agent  run_console 'ToggleVanityMode'  (Kingdom Workshop)", GREEN),
            ("", FG),
            ("queued command:", CYAN),
        ]
        + [(f"  {line}", FG) for line in textwrap.wrap(queued, WRAP - 2)],
    )

    # ---- 5. the bridge turns it into engine calls
    driver = scratch / "driver.lua"
    driver.write_text(
        "\n".join(
            [
                f'package.path = "{KINGDOM}/server-lua/?.lua;" .. package.path',
                'local json = require("kingdom_json")',
                'local Flags = require("kingdom_flags")',
                f'local Bridge = dofile("{KINGDOM}/server-lua/kingdom_bridge.lua")',
                'local calls = {}',
                'local function rec(name) return function(...)',
                '  local a = {...}',
                '  for i, v in ipairs(a) do a[i] = tostring(v) end',
                '  calls[#calls + 1] = name .. "(" .. table.concat(a, ",") .. ")"',
                'end end',
                'local engine = {}',
                'for _, n in ipairs({"InitializeObjectList", "SetObjectListCell", "SetObjectListAction",',
                '  "SetObjectListPid", "SetObjectListConsoleCommand", "SendConsoleCommand"}) do',
                '  engine[n] = rec(n)',
                'end',
                'engine.GetPlayers = function() return {0, 1} end',
                'Bridge.setDependencies({',
                '  engine = engine,',
                '  log = function(m) print("bridge: " .. m) end,',
                '})',
                'Flags.setDependencies({',
                f'  read = function() local f = io.open("{scratch}/flags.json") local b = f:read("*a") f:close() return b end,',
                '  log = function() end,',
                '})',
                'local report = Bridge.drain()',
                'print("applied: " .. tostring(report.applied) .. "   refused: " .. tostring(report.refused))',
                'print("")',
                'print("engine calls the game would now receive:")',
                'for _, c in ipairs(calls) do print("  " .. c) end',
                'print("")',
                'print("applied log entry (what is on the record):")',
                'local f = io.open(Bridge.config.appliedPath)',
                'for line in f:lines() do print("  " .. line) end',
                'f:close()',
            ]
        ),
        encoding="utf-8",
    )
    bridge_out = run([str(LUA), str(driver)], cwd=REPO)
    body: list[tuple[str, tuple[int, int, int]]] = []
    for line in bridge_out.splitlines():
        colour = DIM
        if line.startswith("applied:") or line.startswith("engine calls") or "applied log" in line:
            colour = CYAN
        if line.strip().startswith("SetObject") or line.strip().startswith("Send") or \
                line.strip().startswith("Initialize"):
            colour = GREEN
        if '"agent"' in line:
            colour = YELLOW
        body.append((line, colour))
    script.block("5. The bridge applies it — these are the engine calls the game receives", body)

    # ---- 6. the update path, printed but not performed
    dry = run(["bash", str(KINGDOM / "tools" / "update-world.sh"), "--dry-run"], env=env)
    keep = [line for line in dry.splitlines() if line.strip()][:26]
    script.block(
        "6. Updating the running world: the plan is printed before anything is touched",
        [(line, YELLOW if "missing" in line else (CYAN if line.strip().startswith("==") else DIM))
         for line in keep],
    )

    # ---- 7. the evidence, freshly run
    totals: list[tuple[str, tuple[int, int, int]]] = []
    for name, cmd in (
        ("flags (Lua 5.1)", [str(LUA), str(KINGDOM / "server-lua" / "test_kingdom_flags.lua")]),
        ("bridge (Lua 5.1)", [str(LUA), str(KINGDOM / "server-lua" / "test_kingdom_bridge.lua")]),
        ("auth gate (Lua 5.1)", [str(LUA), str(KINGDOM / "server-lua" / "test_kingdom_auth.lua")]),
    ):
        out = run(cmd, cwd=REPO)
        totals.append((f"{name:<22} {out.splitlines()[-1]}", GREEN))
    for name, cmd, where in (
        ("accounts (python)", ["-m", "unittest", "discover", "-s", "kingdom/auth"], REPO),
        ("mcp tools (python)", ["-m", "unittest", "discover", "-s", "kingdom/agent-api",
                                "-t", "kingdom/agent-api"], REPO),
    ):
        out = run([str(VENV_PY)] + cmd, cwd=where)
        verdict = [line for line in out.splitlines() if line.startswith("OK") or line.startswith("Ran")]
        totals.append((f"{name:<22} {' '.join(verdict)}", GREEN))
    script.block("7. The tests behind all of it, run just now", totals)

    script.card(
        "Where this stands",
        [
            ("", FG),
            ("Built and tested: the tailnet login gate, the", FG),
            ("credential service, the feature flags, the", FG),
            ("agent bridge, 20 MCP tools, the update plan.", FG),
            ("", FG),
            ("Blocked on one thing that is not code:", YELLOW),
            ("Morrowind's data files on this box.", YELLOW),
            ("", FG),
            ("Put them in /home/liamb/morrowind-data/ and", CYAN),
            ("the next demo is the game itself.", CYAN),
        ],
    )
    return script


# --------------------------------------------------------------------------- rendering


def wrap_lines(lines: list[tuple[str, tuple[int, int, int]]]) -> list[tuple[str, tuple[int, int, int]]]:
    wrapped: list[tuple[str, tuple[int, int, int]]] = []
    for text, colour in lines:
        if not text:
            wrapped.append(("", colour))
            continue
        for piece in textwrap.wrap(text, WRAP, replace_whitespace=False) or [""]:
            wrapped.append((piece, colour))
    return wrapped


def draw_frame(draw: ImageDraw.ImageDraw, font: ImageFont.FreeTypeFont,
               bold: ImageFont.FreeTypeFont, title: str, lines: list[tuple[str, tuple[int, int, int]]],
               cursor: bool) -> None:
    draw.rectangle([0, 0, W, 44], fill=BAR)
    draw.text((22, 13), title[:96], font=bold, fill=CYAN)
    y = 66
    for text, colour in lines[-MAX_LINES:]:
        draw.text((22, y), text, font=font, fill=colour)
        y += LINE_H
    if cursor:
        draw.rectangle([22, y - 4, 34, y + LINE_H - 8], fill=GREEN)


def render_card(draw: ImageDraw.ImageDraw, title: str,
                lines: list[tuple[str, tuple[int, int, int]]], big: ImageFont.FreeTypeFont,
                font: ImageFont.FreeTypeFont) -> None:
    draw.rectangle([0, 0, 8, H], fill=MAGENTA)
    draw.text((60, 120), title, font=big, fill=FG)
    y = 210
    for text, colour in lines:
        draw.text((60, y), text, font=font, fill=colour)
        y += 32


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(Path.home() / "Media" / "videos"))
    parser.add_argument("--name", default="kingdom-agent-pipeline.mp4")
    parser.add_argument("--keep-frames", action="store_true")
    args = parser.parse_args()

    if not LUA.exists():
        print("Lua 5.1 is missing — run kingdom/tools/build-lua.sh first", file=sys.stderr)
        return 2
    if not VENV_PY.exists():
        print("the project venv is missing — see kingdom/README.md", file=sys.stderr)
        return 2

    work = Path(tempfile.mkdtemp(prefix="kos-demo-"))
    frames = work / "frames"
    frames.mkdir()
    print(f"scratch: {work}")
    print("running the real pipeline…")
    script = build_script(work)

    font = ImageFont.truetype(FONT_PATH, 19)
    bold = ImageFont.truetype(FONT_BOLD, 19)
    big = ImageFont.truetype(FONT_BOLD, 34)

    index = 0

    def emit(image: Image.Image) -> None:
        nonlocal index
        image.save(frames / f"frame-{index:05d}.png")
        index += 1

    for title, lines in script.blocks:
        if title.startswith("__card__"):
            for _ in range(FPS * 4):
                image = Image.new("RGB", (W, H), BG)
                draw = ImageDraw.Draw(image)
                render_card(draw, title.replace("__card__", ""), lines, big, font)
                emit(image)
            continue

        wrapped = wrap_lines(lines)
        pages = [wrapped[i:i + MAX_LINES] for i in range(0, len(wrapped), MAX_LINES)] or [[]]
        for page in pages:
            for shown in range(1, len(page) + 1):
                head = [(t, c) for t, c in page[:shown]]
                for _ in range(FRAMES_PER_LINE):
                    image = Image.new("RGB", (W, H), BG)
                    draw = ImageDraw.Draw(image)
                    draw_frame(draw, font, bold, title, head, cursor=(shown == len(page)))
                    emit(image)
            # hold the finished page for a beat
            for _ in range(FPS // 2):
                image = Image.new("RGB", (W, H), BG)
                draw = ImageDraw.Draw(image)
                draw_frame(draw, font, bold, title, page, cursor=False)
                emit(image)

    if index > MAX_FRAMES:
        print(f"note: {index} frames ({index / FPS:.0f}s) — longer than planned", file=sys.stderr)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    target = out / args.name
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS),
         "-i", str(frames / "frame-%05d.png"),
         "-c:v", "libx264", "-preset", "medium", "-crf", "21",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(target)],
        check=True,
    )
    size_mb = target.stat().st_size / 1e6
    print(f"\n{index} frames, {index / FPS:.1f}s, {size_mb:.1f} MB")
    print(f"video: {target}")
    if not args.keep_frames:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"frames kept in {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
