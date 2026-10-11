# Operating the Kingdom — flags, updates, and how nothing blows up

The rule behind everything in this file: **an experiment is never live by accident.** It is compiled
out, or off by name, or on a branch that is not the one running. Changing the world is a deliberate
act with a record and a way back.

---

## 1. Feature flags

Two classes, and the difference matters:

| Class | Examples | Default | Governed by |
|---|---|---|---|
| **Baseline** — what the world exists to do | `world_edits`, `weather_control`, `avatar_control`, `screenshots`, `world_speech` | on | the file alone |
| **Experiments** — `exp_` | `exp_custom_models`, `exp_npc_control`, `exp_console`, `exp_player_remodel`, `exp_scheduled_weather`, `exp_hot_reload` | off | the file **and** the `experiments` master switch |

Four rules, enforced in code rather than by discipline:

1. **Unknown names are always off.** A flag that is not in the server's known list stays off whatever
   the file says, so a typo, a stale file or a hostile edit cannot enable behaviour that does not
   exist. Both the Lua side and the MCP server implement this independently.
2. **The master switch overrides everything.** With `experiments: false`, no `exp_` flag is live even
   if it is named in the file.
3. **Every applied command records the flag state that produced it.** When something looks wrong, the
   log says which combination was live — so "it worked yesterday" becomes a checkable fact.
4. **Flags are read fresh on every game event** (server) and every tool call (MCP). Flipping one
   needs no restart and no reconnect.

```bash
bash kingdom/tools/kos-flags.sh list                 # what exists, what is live
bash kingdom/tools/kos-flags.sh set exp_console on    # one experiment
bash kingdom/tools/kos-flags.sh set experiments on    # the master switch
```

Seeding the world's copy of the file the first time:

```bash
install -D -m 0600 kingdom/flags.json /home/liamb/kos-world/flags.json
```

The file lives with the queue and the saves — outside the shared folder, so no guest can flip
anything.

## 2. Where a change goes, and which branch it lives on

```
  0.8.1                    upstream mirror. never committed to. the diff base.
    └── kingdom/world      integration: everything that actually runs
          ├── kingdom/exp/<name>     one experiment per branch, branched from kingdom/world
          └── kingdom/release/<date> tags: known-good states, and the rollback targets
```

The rules that keep an experiment from taking the world with it:

- **Work on `kingdom/exp/<name>`, not on `kingdom/world`.** Merge only when the thing works.
- **Every risky change lands behind a flag first, default off.** A merged feature that is off cannot
  affect a session; graduating it is one line in `flags.json`.
- **Tag before every update:** `git tag kingdom/release/2026-10-11` — that tag is the rollback point.
- **`0.8.1` stays pristine.** It is the only way to tell our changes from upstream's, and it makes
  `git diff 0.8.1...kingdom/world` the honest answer to "what have we done to this engine?".

Checking the current state of the tree:

```bash
git log --oneline kingdom/release/<last>..kingdom/world    # what changed since the last known-good
git diff --stat 0.8.1...kingdom/world -- apps components    # what we changed in the engine itself
```

## 3. Updating the running world

Two kinds of change, and they cost very different amounts:

| Change | Needs | Player experience |
|---|---|---|
| Lua (our scripts, most agent features) | server restart (the engine has **no** script reload — verified) | dropped, back in seconds, same character |
| Engine (C++) | rebuild, then a binary swap | dropped, back in seconds, same character |

`kingdom/tools/update-world.sh` does the whole sequence, and refuses to do anything irreversible:

1. **Save.** Ask the running server to publish its state and drain the queue (`OnServerExit` runs the
   same two calls), and copy the save directory to a backup. An update you cannot undo is not safe.
2. **Build** (only if engine files changed) into a *staging* path. The running binary is never
   overwritten while it runs.
3. **Smoke test the new build** on a scratch port with the same data. A binary that cannot boot
   fails here, not in front of two players.
4. **Swap atomically** — flip a `current` symlink — and restart the service.
5. **Roll back automatically** if it does not come up: flip the symlink back, restart, and say so.

```bash
bash kingdom/tools/update-world.sh --dry-run     # print every step, change nothing
bash kingdom/tools/update-world.sh               # do it
```

## 4. Reconnecting the players

The honest state of this, as of today: **the fork has no auto-reconnect in the client** (searched:
`apps/openmw/mwmp`, `apps/openmw/mwgui` — nothing), and the server has no script reload. So a restart
drops the session and the plan is staged:

1. **Now (no code):** the server announces the reload in chat a few seconds ahead; players return by
   picking the server again. Same identity, same password, same save — no re-enrolment, no typing of
   anything but going back in. The gap is the restart time (~2–5 seconds), plus the time it takes a
   person to click.
2. **Next (flagged, `exp_hot_reload`):** a client-side change in our fork so the Morrowind client
   reconnects itself — exponential backoff, remembering the password in memory for the session, and
   resuming where it was. This is a C++ change in `apps/openmw/mwmp`, so it gets its own branch
   (`kingdom/exp/reconnect`), a flag, and a rebuild; the world keeps running the old client until it
   is proven.
3. **Then:** if the reconnect proves solid, the same machinery makes Lua reloads nearly invisible,
   which is what most agent features actually need.

The seamlessness we can promise today is: **the world comes back exactly as it was, and the players
get back in with one click.** The seamlessness after step 2 is: they never noticed.

## 5. When something does go wrong

- **A bad engine build:** `update-world.sh` rolls back on its own. Manually:
  `git checkout kingdom/release/<last>` and rebuild, or flip the `current` symlink back.
- **A bad Lua change:** it is in `kingdom/world`; `git revert` the commit. Flags mean most experiments
  never needed a revert at all.
- **A bad agent action:** the applied log has the agent, the command, the outcome and the flag state.
  Reversing it is another command through the same path (`delete_object`, `move_object`).
- **Credentials or identity trouble:** `kos_auth.py status` (accounts, audit chain integrity),
  `admin-reset --user-id …` to re-mint one password, `audit-verify` to see whether the log has been
  tampered with.

## 6. What is not switched by flags

Deliberately outside the flag system, because a flag must never be able to undo them:

- who may connect at all (the tailnet guest list — Liam and Robby's user ids);
- the cell allow-list for agent edits (a code change, reviewed like any other);
- the credential rules (hashes, lockouts, the audit chain);
- attribution on every command.
