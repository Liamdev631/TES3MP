# Verification — what was actually run and what it returned

Host: `beelink`, Ubuntu 26.04, user `liamb`, no root/sudo. Docker 29.8.0 (snap), Tailscale 1.102.3
(host), image base Python 3.11.17. Image `kos-node:local` built from `deploy/Dockerfile`.
Container `kos-node` run capability-free (`--cap-drop ALL`, `--read-only`, own bridge `kosnet`,
userspace Tailscale). **No auth key was available**, so the node is *not* joined — that is the one
`BLOCKED` item.

---

## 1. Credential search — PRESENCE ONLY (no value printed)

```/dev/null
$ grep -oE '^[A-Z_]*TAILSCALE[A-Z_]*|^TS_[A-Z_]*'  <each .env>     # .hermes/.env, profiles/*/.env, hermes-share/.env, hermes-servers/.env
(no output — no Tailscale/TS_ variables in any of them)

$ grep -rIl -E 'tskey-|TS_AUTHKEY|TAILSCALE_API|TS_OAUTH' ~/.config ~/.local/share /etc/systemd/user ~/.hermes
  .hermes/profiles/worldsmith/cache/delegation/live/deleg_e53ef9e4/task-0.log
  .hermes/profiles/{trainer,admin}/skills/sysadmin/beelink-services/SKILL.md
  .hermes/profiles/admin/hook_outputs/20261011_051254_803959e5/{f0b30128,6a16f439}....txt
$ ... characterized each without revealing values:
  beelink-services/SKILL.md  -> 'tskey-' with 20 placeholder-ish lines (documentation of how to create a key)
  worldsmith task-0.log      -> literal string "tskey-" only (no key body)
  admin hook_outputs         -> placeholder-ish / redacted
$ docker secret ls          -> "This node is not a swarm manager"    (no swarm secrets)
```

**Conclusion:** no live, reusable Tailscale auth key or API/OAuth token is stored on this box. This
matches `hermes-share/ACL-kingdom.md`: "no API key is stored on beelink".

---

## 2. The node is capability-free and separate from the host

```
$ docker inspect kos-node --format '...'
Privileged:        false
CapAdd:            []
CapDrop:           [ALL]
NetworkMode:       kosnet
ReadonlyRootfs:    true
SecurityOpt:       []
Devices:           []
PidMode:
Binds:             [/home/liamb/kos-world:/kos-world
                    /home/liamb/projects/TES3MP/kingdom/agent-api/kos_mcp.py:/app/kos_mcp.py:ro
                    /home/liamb/projects/TES3MP/kingdom/.venv:/venv:ro
                    kos-node-state:/var/lib/tailscale]

$ docker inspect kos-node --format '{{range .Mounts}}...'   # mounts actually present
bind   /home/liamb/kos-world                                  -> /kos-world    (rw=true)
bind   /home/liamb/projects/TES3MP/kingdom/.venv              -> /venv         (rw=false)
bind   /home/liamb/projects/TES3MP/kingdom/agent-api/kos_mcp.py -> /app/kos_mcp.py (rw=false)
volume kos-node-state/_data                                  -> /var/lib/tailscale (rw=true)

$ docker exec kos-node sh -c 'ls /var/run/docker.sock /run/docker.sock /dev/net/tun'
ls: cannot access '/var/run/docker.sock': No such file or directory
ls: cannot access '/run/docker.sock':       No such file or directory
ls: cannot access '/dev/net/tun':           No such file or directory

$ # interfaces inside the container (userspace networking => NO tailscale0 tun device)
$ docker exec kos-node cat /proc/net/fib_trie           # only 0.0.0.0/0 and 127/8 — no tailscale0

$ docker exec kos-node tailscale status
Logged out.
$ docker exec kos-node tailscale ip
no current Tailscale IPs; state: NeedsLogin
$ # contrast: the HOST's own daemon is a different, already-running node
$ tailscale status | head -2
100.102.189.126  beelink  liamdev631@  linux  -
100.68.224.1     moto     liamdev631@  android  offline, last seen 10h ago
```

✔ No privileges, no capabilities, no tun device, no Docker socket, own bridge, only the game
mounts. The container has its **own** tailscaled daemon, distinct from the host's.

---

## 3. Reachability from inside the container (real output)

```
$ docker exec -i kos-node python3 - <<'PY'   # TCP connect probes, 3s timeout
container gateway (host): 172.20.0.1

127.0.0.1:9119        BLOCKED (ConnectionRefusedError: [Errno 111] Connection refused)   host hermes agent (loopback)
127.0.0.1:8642        BLOCKED (ConnectionRefusedError: [Errno 111] Connection refused)   host link agent (loopback)
127.0.0.1:9120        BLOCKED (ConnectionRefusedError: [Errno 111] Connection refused)   host shared folder (loopback)
127.0.0.1:9121        BLOCKED (ConnectionRefusedError: [Errno 111] Connection refused)   host rendered site (loopback)
100.102.189.126:9119  OPEN    host hermes agent (tailnet IP)
100.102.189.126:8642  OPEN    host link agent (tailnet IP)
100.102.189.126:9120  OPEN    host shared folder (tailnet IP)
100.102.189.126:9121  OPEN    host rendered site (tailnet IP)
100.102.189.126:443   OPEN    host vault (tailnet IP)
100.102.189.126:10000 OPEN    host service (tailnet IP)
172.20.0.1:8888       OPEN    host searxng (0.0.0.0)
172.20.0.1:22         OPEN    host ssh (0.0.0.0)
172.20.0.1:3000       OPEN    host dev (0.0.0.0)

HTTP GET http://100.102.189.126:9119/ -> 200 uvicorn      # real HTTP response from the host's agent
```

- ✔ **Proven blocked:** the host's loopback-only services (`127.0.0.1:*`) — the container has its
  own loopback / its own Docker bridge, so these are refused.
- ✘ **Proven reachable (limitation):** the host's own IPs — the tailnet IP `100.102.189.126:*` and
  the `0.0.0.0` services via the gateway `172.20.0.1`. On a Docker bridge the host *is* the
  container's gateway, so a host-local address is delivered locally. This is inherent to
  no-root bridge networking (a macvlan network, which would avoid it, does **not** work over this
  box's Wi-Fi — tested: the container gets a LAN IP but the AP drops its frames, router and
  internet both unreachable). Closing it needs a root `DOCKER-USER` iptables rule (given in
  `README.md`), or binding those host services to `127.0.0.1`.
- **Not a path Robby can use:** the container runs no proxy/forwarding — only the MCP server — so a
  tailnet peer cannot pivot through it to these host services.

---

## 4. The game surface runs and answers (real output)

```
$ docker exec kos-node python3 -c "import sys; sys.path.insert(0,'/app'); import kos_mcp; print(kos_mcp.tool_world_status())"
{'game_connected': False, 'state': None,
 'note': 'The game has not reported in yet (no fresh snapshot at /kos-world/world-state.json). 0 command(s) are waiting in the queue and will be applied when it starts.',
 'queued': 0, 'you_are': 'kos-node', 'writes_allowed': True,
 'flags': {'experiments': False, 'world_edits': True, 'weather_control': True, 'avatar_control': True,
           'screenshots': True, 'world_speech': True, 'exp_custom_models': False, 'exp_npc_control': False,
           'exp_console': False, 'exp_scheduled_weather': False, 'exp_player_remodel': False, 'exp_hot_reload': False},
 'flags_file': '/kos-world/flags.json'}
```

**The twenty tools the server registers** (`build_server().list_tools()`):

```
world_status, list_flags, list_players, recent_activity, spawn_object, define_model, move_object,
scale_object, delete_object, set_weather, set_time, move_npc, set_npc_health, kill_npc,
teleport_player, set_avatar_model, set_avatar_stats, say, run_console, take_screenshot
```

**Real MCP handshake over streamable-HTTP** (`http://127.0.0.1:8000/mcp`, from inside the box):

```
initialize  -> kingdom | protocol 2025-11-25
list_tools  -> 20 tools
world_status-> {"game_connected": false, "state": null,
                "note": "The game has not reported in yet (no fresh snapshot at /kos-world/world-state.json)...
list_flags  -> live: ['avatar_control', 'screenshots', 'weather_control', 'world_edits', 'world_speech']
```

**Write path, proved against a throwaway world (the real queue was left untouched):**

```
refused (bad cell): Refused -> 'Not Allowed Cell' is not a cell agents may change. Allowed: ...
queued record: {"action": "spawn_object", "agent": "kos-node-probe", "at": 1791714361.998,
                "cell": "Balmora", "count": 1, "id": "8bcc743ee3e9",
                "position": [-100, 0, 50], "refId": "furn_com_crate_01"}
queue.jsonl   : (the record above)
$ wc -l < /home/liamb/kos-world/queue.jsonl
0                                     # the real game queue was not polluted
```

✔ The unmodified `kos_mcp.py` runs in the box, reads `/kos-world`, enforces the cell allow-list,
attributes commands to `KOS_AGENT`, and answers over the real MCP HTTP transport.

---

## 5. What is PROVEN vs BLOCKED

**PROVEN**
- A userspace Tailscale node runs in the container with **no ** privileged / cap-add / `/dev/net/tun` —
  verified `Privileged:false`, `CapDrop:[ALL]`, `Devices:[]`, and `tailscaled --tun=userspace-networking`
  is the running process (image `tailscale` 1.102.5; `--auth-key`/`--hostname` available in-image).
- The container is its **own** node, distinct from the host (own daemon, own state volume; host
  daemon untouched — the host config was never modified and `tailscale up` was never run on it).
- Only the game files are mounted: `/kos-world` rw, `kos_mcp.py` + `.venv` ro, plus the node's state
  volume. No Docker socket, no host network namespace, no tun device.
- The host's loopback services are unreachable from inside the box (connection refused).
- `kos_mcp.py` runs in the box against `/kos-world`; all 20 tools register; a full MCP
  initialize → list_tools → call_tool exchange succeeds over streamable-HTTP.

**BLOCKED (one item)**
- **The node is not joined, because no tailnet auth key exists on this box.** Until a key is
  supplied the node stays `Logged out` and so cannot yet be shown at its own `100.x` address or
  reached by Robby. Everything else about the box is verified independently of joining.

**KNOWN LIMITATION (honest)**
- The box can reach the host's own IPs through the Docker bridge (see §3). Not exploitable by Robby
  (no proxy), but not full network isolation from the host; needs the root firewall rule in
  `README.md` to close.

---

## 6. The single command the operator must run

Create an auth key (admin console → **Settings → Keys → Generate auth key**, mark it **Reusable**,
leave Ephemeral off), then:

```bash
TS_AUTHKEY=tskey-auth-XXXXXX docker compose -f /home/liamb/projects/TES3MP/kingdom/deploy/docker-compose.yml up -d
```

Then, in **Access controls**, narrow the broad rule to `autogroup:member` and add:
`{ "action": "accept", "src": ["autogroup:shared"], "dst": ["kos-node.tail96c9e1.ts.net:443"] }`.
