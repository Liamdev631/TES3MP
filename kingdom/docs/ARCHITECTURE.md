# The Kingdom of Science — a private Morrowind world for two players

This is the plan of record for turning Liam's TES3MP fork into our own world: Robby and Liam play
Morrowind together, our agents (on both sides) can edit the live game — spawn objects, swap models,
look at the result from any angle — and nobody else can get in at all.

Everything below is written against the fork in this repository
(`Liamdev631/TES3MP`, branch `0.8.1`), not against upstream, and capabilities marked **verified**
were read out of this tree.

---

## 1. The shape of it

```
   Robby's PC ─┐                                    ┌─ kos_auth.py ── accounts (scrypt hashes)
               ├── tailnet (100.x) ── TES3MP server ─┤                 audit.jsonl (hash chain)
   Liam's PC ──┘      only these two               └─ agent bridge ── kingdom/queue/*.json
                                                                      └─ screenshot helper
```

Three separate things, deliberately:

| Piece | Job | Where it lives |
|---|---|---|
| **TES3MP server** (this fork) | the game itself; world state and per-player saves | `server/` on beelink, bound to the tailnet address |
| **Auth service** (`kingdom/auth/`) | decides who a connecting IP *is*, mints and checks the one password | `/home/liamb/kos-auth/`, 0700, never on the tailnet |
| **Agent bridge** (`kingdom/agent-api/`, planned) | the HTTP surface our agents call to edit the live world | localhost + a token per agent |

The world state, the saves and the credentials are deliberately **not** in
`hermes-share/KingdomOfScience/` — the browser world lives there, and that folder is readable by
Robby's agent. Game data does not go where a guest can reach it.

---

## 2. Access: private, and proven private

Four gates, in order, and none of them is "type a name":

1. **The tailnet.** The server binds to the beelink tailnet address (`100.102.189.126`) rather than
   `0.0.0.0`, so the game port is not reachable from the LAN or the internet at all.
2. **The guest list.** On every connection the server asks `tailscale whois <ip>` who owns that
   address, and refuses anyone whose tailnet *user id* is not Liam's (`7230364925941255`) or
   Robby's (`6123606715262792`). This runs before enrolment, so a stranger can never create an
   account — there is nothing for them to log in *to*.
3. **The password.** First connection for an allowed identity mints a password, shows it once, and
   asks the player to save it. Stored as a scrypt hash; the plaintext is never written down.
4. **The game's own account system** is bypassed for this: CoreScripts must not keep a second,
   weaker copy of the password.

Also still worth doing (one console action, Liam's): narrow the Tailscale ACL so the two gaming
ports are the only thing the *shared* user can reach — the current policy lets a guest reach every
service on this box. That is defence in depth: gate 2 already covers the game port itself.

### Why the identity is trustworthy

`tailscale whois` is answered by the local tailnet daemon, not by the client. The game's UDP socket
tells us the source address, we ask the daemon who that address belongs to, and the client cannot
influence the answer. Two consequences worth stating plainly:

- A player cannot claim to be someone else's account: their tailnet user id decides which account
  is even looked up.
- Liam's node and Robby's node are *different user ids*, so neither can borrow the other's account
  by changing a name or a client setting.

---

## 3. What the fork already gives us (verified in-tree)

This is why the Morrowind route works where the Skyrim route did not: the capabilities we need are
already in the server's Lua API, so agents can shape the world **live**, without an engine rebuild
and without restarting anyone's client.

| Need | Already present | Where |
|---|---|---|
| Who is connecting | `GetIP(pid)` | `apps/openmw-mp/Script/Functions/Server.cpp:115` |
| Spawn an object | object-list setters (`SetObjectRefId`, `SetObjectRefNum`, `SetObjectMpNum`, `SetObjectListCell`, position/rotation/scale) then the `SendObject*` calls | `.../Functions/Objects.hpp` |
| Remove / restack objects | `SendObjectDelete`, `SendObjectPlace`, `SetObjectListAction` (SET/ADD/REMOVE/REQUEST) | `.../Functions/Objects.hpp` |
| **Invent a new object type with a custom model** | dynamic records: `SetRecordType`, `SetRecordModel`, `AddRecord`, `SendRecordDynamic` | `.../Functions/RecordsDynamic.hpp:41,49,139` |
| Drive a client to a spot (for a photo) | `SetObjectListConsoleCommand` — a console command runs on the client that holds the object | `.../Functions/Objects.hpp:899` |
| Chat to one player | `SendMessage(pid, text)` | `.../Functions/Chat.hpp` |
| Events we hang off | `OnPlayerConnect`, `OnPlayerSendMessage`, `OnPlayerDisconnect`, `OnObjectSpawn`, `OnObjectScale`, `OnConsoleCommand`, … | `apps/openmw-mp/Script/*.cpp` |
| Lua can call out | the server Lua state is opened with `luaL_openlibs`, so `io.popen` works — the auth CLI is callable | `apps/openmw-mp/Script/LangLua/LangLua.cpp:37` |

Two limits found, both worth knowing now rather than later:

- **No timer/tick callback** in the server Lua API. The agent bridge therefore drains its command
  queue on engine events rather than on a clock.
- **No screenshot function exposed to scripts.** OpenMW has the machinery
  (`apps/openmw/mwrender/screenshotmanager.cpp`) but nothing in the Lua surface calls it. Until we
  add a binding, the screenshot helper drives a running client externally (position it by console
  command, capture the window); with a binding it becomes a one-line agent call. We own the tree,
  so both paths are open — the external one works first.

---

## 4. Personal persistent saves

Each player keeps their own progress; the *identity* is the key, not a typed character name. The
gate resolves identity → a fixed save name (`liam` / `robby`) held in
`kingdom/server-lua/kingdom_auth.lua`, so a player's state follows them across devices (Liam plays
from StarHelix or anywhere on the tailnet; Robby's three devices all resolve to his user id).

Persistence itself is TES3MP's job: world state plus per-player data, written on the server, which
is what makes "just connect and your world is where you left it" true. CoreScripts (see below) is
what implements the per-player file layout, so the save path is configured there and kept off the
shared folder.

---

## 5. Agent integration (the part that is new)

Goal: either side's agents can see and shape the world through a small, boring HTTP API, with no
agent ever holding a player's password.

Planned surface, each call mapping onto calls the fork already has:

| Call | Effect | Built on |
|---|---|---|
| `GET /v1/status` | who is online, which cells are loaded, what the bridge has done | roster + audit |
| `GET /v1/cells/{cell}/objects` | what is in a cell right now | object list |
| `POST /v1/objects` | spawn an object at a position, with a scale and rotation | `SetObject*` + `SendObjectPlace` |
| `POST /v1/records` | define a **new** object type pointing at a model we supply, then spawn it | `SetRecordModel` + `AddRecord` + `SendRecordDynamic` |
| `PATCH /v1/objects/{id}` | move / rotate / rescale / swap the model of a live object | same, with the object's mpNum |
| `DELETE /v1/objects/{id}` | remove it | `SendObjectDelete` |
| `POST /v1/screenshots` | put the camera somewhere and return a picture | console command + capture |
| `POST /v1/console` | run a console command on a chosen client (admin only) | `SetObjectListConsoleCommand` |

Rules the bridge enforces, so "versatile" does not become "unaccountable":

- Every agent gets **its own token**; every write is attributed in an append-only log.
- Writes are limited to a set of cells we nominate as fair game, so no agent can quietly rework
  the world's main quest areas.
- `POST /v1/console` is the sharp tool, and it is admin-only.
- The bridge never sees a password and cannot mint an account — it is not in the auth path at all.

Screenshot flow, concretely: keep one client running on the box's own display (`:1`, AMD GPU,
accelerated) as a camera drone; the bridge tells it where to stand and which way to look, then
captures the frame and publishes it to the media server so the result can be looked at from chat.
That is the "confirm appearances" loop: an agent changes a model, asks for a photo, and sees
whether it worked.

---

## 6. Keeping agents out of the credentials

Stated as an engineering position rather than a promise, because the honest boundary matters:

- **What is protected.** Passwords exist only as scrypt hashes in `/home/liamb/kos-auth/accounts.json`
  (0600, in a 0700 directory, outside every shared folder). Reading that file yields nothing usable:
  no plaintext, no reusable token. The admin token that can re-mint a password is a separate 0600
  file.
- **What is detectable.** Every enrolment, login, failure, lockout and reset is appended to
  `audit.jsonl` with a hash chain: each entry carries the hash of the one before it, so editing,
  reordering or deleting a line breaks the chain and `kos_auth.py audit-verify` says so.
- **What is *not* protected, and cannot be without root.** Every agent on this box — mine and any
  future one — runs as the user `liamb`, and so does the auth service. Same user means an agent can
  *read* the hash file and *could* delete or replace it (which the audit chain then exposes). It
  cannot recover a password from it and it cannot log in as anyone: it would have to know the
  plaintext, and the identity check means it would also have to be sitting on that person's device.
- **The one action that closes it properly.** Create a dedicated system user (say `kosgame`) and
  run the auth service and the game server under it, with `kos-auth/` owned by that user and not
  readable by `liamb`. That needs a root password, which this agent does not have. A script to do
  it in one step is the next thing to write; until it runs, the layer above is what you have.

Robby's side is better protected than that sentence suggests: his agent runs on *his* machine and
has no filesystem access here at all. Everything it can reach is what the tailnet exposes, and the
game port will be the only thing that answers.

---

## 7. Build and run

- **Write Lua first, build second.** The login gate and the agent bridge are server scripts; the
  fork's Lua API is already sufficient for both. `kingdom/server-lua/kingdom_auth.lua` is written
  and tested (46 assertions, `kingdom/server-lua/test_kingdom_auth.lua`, run under the same Lua 5.1
  the engine embeds — `kingdom/tools/lua-5.1/bin/lua`).
- **Two ways to get the engine running:** the upstream 0.8.1 Linux binaries (fastest — the fork is
  at 0.8.1, so binaries match the source), or build this tree in a container using the dependency
  list the repo already ships (`CI/install_debian_deps.sh`: Boost, FFmpeg, SDL2, Qt5, OpenAL,
  libunshield, TinyXML, Bullet, LZ4, MyGUI, OpenSceneGraph, plus bundled RakNet). A container build
  is needed once we touch engine code (the screenshot binding); until then the binaries get us
  playing sooner. It needs no root: the toolchain goes inside the image.
- **CoreScripts is a dependency to fetch.** This tree ships no Lua at all; the server-side script
  set that implements chat, login and per-player saving lives in the TES3MP CoreScripts repository
  and is loaded by the server. Our gate sits beside it and takes over the login decision.

## 8. Blockers

1. **Morrowind data files are not on this box.** Nothing starts without `Morrowind.esm`,
   `Tribunal.esm`, `Bloodmoon.esm` and their BSAs. Liam and Robby own the game; the files need
   copying from one of their installs to a data directory here.
2. **No root**, so the credential store cannot be put behind a separate UID yet (section 6), and
   system packages cannot be installed on the host (a container covers the build).

## 9. Layout

```
kingdom/
  auth/            kos_auth.py          tailnet identity → account, scrypt, audit chain
                   test_kos_auth.py     21 tests
  server-lua/      kingdom_auth.lua     the login gate the server runs
                   test_kingdom_auth.lua 46 assertions under Lua 5.1
  tools/lua-5.1/   bin/lua              the interpreter the engine embeds, for testing
  docs/            ARCHITECTURE.md      this file
  agent-api/       (planned)            the HTTP surface for our agents
```
