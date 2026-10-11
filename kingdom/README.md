# kingdom — our Morrowind world

A private Morrowind world for Liam and Robby, built on this fork of TES3MP, with an agent API so
our agents can shape the live game. The design and the reasoning are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); this file is just how to touch the pieces.

## Accounts: who you are is decided by the tailnet

The username is not chosen and not typed. The server hands the auth service the connecting
player's IP, the tailnet says which account and device that is, and the password — minted on first
connection and shown once — is what proves it is really them.

```bash
# who is this address?
python3 kingdom/auth/kos_auth.py identify --ip 100.109.247.50

# accounts (never secrets) and audit-chain integrity
python3 kingdom/auth/kos_auth.py status
python3 kingdom/auth/kos_auth.py audit-verify

# operator recovery: re-mint someone's password (needs the admin token)
python3 kingdom/auth/kos_auth.py admin-reset --user-id 6123606715262792
```

State lives in `/home/liamb/kos-auth/` (0700; `accounts.json`, `audit.jsonl`, `admin.token`, all
0600). Passwords are stored only as scrypt hashes; every auth event is appended to a hash-chained
log so edits are visible after the fact. Set `KOS_AUTH_DIR` or `--store` to test elsewhere.

## The agent surface: MCP tools

Agents do not talk to the game; they get tools. `kingdom/agent-api/kos_mcp.py` is an MCP server whose
twenty tools write one command each into the queue that `kingdom/server-lua/kingdom_bridge.lua`
drains — so nothing needs the game to be running, and the answers come back through the state file
the game publishes.

```bash
kingdom/.venv/bin/python kingdom/agent-api/kos_mcp.py    # stdio; point any MCP client at it
```

Tools: `world_status`, `list_flags`, `list_players`, `recent_activity`; objects — `spawn_object`,
`define_model` (a new object type pointing at a model file, live), `move_object`, `scale_object`,
`delete_object`; world — `set_weather`, `set_time`; people — `move_npc`, `set_npc_health`,
`kill_npc`; avatars — `teleport_player`, `set_avatar_model`, `set_avatar_stats`; plus `say`,
`run_console` and `take_screenshot`. Environment: `KOS_WORLD_DIR`, `KOS_AGENT`, `KOS_FLAGS_FILE`,
`KOS_MCP_READONLY`.

Three rules hold on both sides of the queue: unknown flags are off, only cells on the allow-list can
be changed, and every command is logged with the agent that sent it and the flags that were live.

## Feature flags, and not blowing things up

Every non-trivial change lands behind a flag, defaulting off for anything experimental, so a
half-finished idea can be compiled, loaded and reachable without being able to touch a session.

```bash
bash kingdom/tools/kos-flags.sh list                 # what exists and what is live
bash kingdom/tools/kos-flags.sh set exp_console on    # one experiment
bash kingdom/tools/kos-flags.sh set experiments on    # the master switch
```

Baseline capabilities (`world_edits`, `weather_control`, `avatar_control`, `screenshots`,
`world_speech`) are on; everything named `exp_` is off until the master switch *and* the flag say
otherwise, and a flag the code does not know is always off. The server re-reads the file on every
game event, so flipping one needs no restart.

## Tests

```bash
python3 -m unittest discover -s kingdom/auth -v                            # 21: hashing, lockouts, audit chain
kingdom/.venv/bin/python -m unittest discover -s kingdom/agent-api -t kingdom/agent-api   # 21: MCP tools, flags
kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_flags.lua     # 25: the flag rules
kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_bridge.lua    # 88: commands → engine calls
kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_auth.lua      # 46: the login gate
kingdom/tools/build-lua.sh            # the Lua 5.1 the engine embeds, built locally for the tests
```

## Live updates, and the way back

`kingdom/tools/update-world.sh --dry-run` prints the whole update: back up the save, build into a
staging path, smoke-test the new build, swap it in, and roll back on its own if it does not come up.
The branching and rollback rules, and the state of player reconnection, are in
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## Visual proof

```bash
kingdom/.venv/bin/python kingdom/tools/demo_pipeline.py    # a real session → MP4 in ~/Media/videos
```

It runs the pipeline for real — flags, the MCP tool being refused and then allowed, the bridge
turning that into engine calls, the update dry run, the test totals — and renders the transcript as
a video, so a claim in a message can be watched instead of taken on faith.

## The login gate

`kingdom/server-lua/kingdom_auth.lua` is loaded by the TES3MP server. On connect it resolves the
tailnet identity, checks the guest list (Liam and Robby only), then either mints a password or asks
for one. It talks to the auth service by running its CLI (`luaL_openlibs` means `io.popen` is
available), caches identities for five minutes, and kicks after repeated failures.

## Hardening the credential store (needs root, once)

```bash
sudo kingdom/tools/setup-system-user.sh    # review it first; prints every change it makes
```

Until that runs, the auth store is protected by permissions and hashes rather than by a separate
user — see section 6 of the architecture note for exactly what that does and does not buy.

## Status

Working and tested: the auth service, the login gate, the tailnet identity check, the guest list.
Next: fetch CoreScripts and the Morrowind data files, run the server, then build the agent bridge
(spawn objects, swap models, take screenshots).
