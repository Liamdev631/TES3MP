# Kingdom of Science — game surface as its own isolated tailnet device

This directory runs the Kingdom of Science agent surface (`kos_mcp.py`, twenty MCP tools) inside a
Docker container that joins the tailnet **as its own device**, so an outside tailnet user (Robby)
can reach the game and nothing else on this box.

It is **capability-free on purpose.** The container runs Tailscale in *userspace* mode
(`TS_USERSPACE=true`, `tailscaled --tun=userspace-networking`), so it needs **no `--privileged`, no
`--cap-add=NET_ADMIN`, no `/dev/net/tun`** — none of which this host (no root) could grant. All
capabilities are dropped (`cap_drop: ALL`) and the root filesystem is read-only.

## Files

| File | Role |
|---|---|
| `Dockerfile` | `python:3.11-slim` + the static Tailscale binaries copied from `tailscale/tailscale:latest` + `mcp==2.3.0` (same SDK version as `kingdom/.venv`). |
| `entrypoint.sh` | Starts `tailscaled` in userspace mode; if `TS_AUTHKEY` is set, joins the tailnet and publishes **only** the game surface; then runs the MCP server. |
| `mcp_http.py` | Serves `kos_mcp.py` over MCP streamable-HTTP on `127.0.0.1:8000` (loopback only). The tailnet surface is the `tailscale serve` route in the entrypoint. |
| `docker-compose.yml` | The whole thing as one service, `kos-node`, with the mount and hardening flags. |
| `VERIFICATION.md` | The real command output proving the isolation and the working surface. |

## Mounts (the only things in the box)

| Host path | In container | Mode |
|---|---|---|
| `/home/liamb/kos-world` | `/kos-world` | read/write (the game MCP files: queue, state, flags, screenshots) |
| `/home/liamb/projects/TES3MP/kingdom/agent-api/kos_mcp.py` | `/app/kos_mcp.py` | read-only |
| `/home/liamb/projects/TES3MP/kingdom/.venv` | `/venv` | read-only |
| named volume `kos-node-state` | `/var/lib/tailscale` | the node's own identity/state |

No Docker socket, no host network namespace, no `/dev/net/tun`.

## Run it

### 1. Build (already done — `kos-node:local` exists)

```bash
docker build -t kos-node:local /home/liamb/projects/TES3MP/kingdom/deploy
```

### 2. Start — the one command (needs a tailnet auth key; see below)

```bash
TS_AUTHKEY=tskey-auth-XXXXXX docker compose -f /home/liamb/projects/TES3MP/kingdom/deploy/docker-compose.yml up -d
```

Equivalent plain `docker` (no compose):

```bash
docker network create kosnet 2>/dev/null || true
docker run -d --name kos-node --restart unless-stopped \
  --network kosnet \
  --read-only --tmpfs /tmp --tmpfs /run --tmpfs /var/run/tailscale --tmpfs /root/.cache \
  --cap-drop ALL \
  -e TS_USERSPACE=true -e TS_AUTHKEY=tskey-auth-XXXXXX -e KOS_AGENT=kos-node \
  -v /home/liamb/kos-world:/kos-world \
  -v /home/liamb/projects/TES3MP/kingdom/agent-api/kos_mcp.py:/app/kos_mcp.py:ro \
  -v /home/liamb/projects/TES3MP/kingdom/.venv:/venv:ro \
  -v kos-node-state:/var/lib/tailscale \
  kos-node:local
```

### 3. Stop / inspect

```bash
docker compose -f /home/liamb/projects/TES3MP/kingdom/deploy/docker-compose.yml down   # stop + remove
docker logs kos-node                                             # what it is doing
docker exec kos-node tailscale status                            # this node's own identity
docker inspect kos-node --format '{{.HostConfig.Privileged}} {{.HostConfig.CapDrop}} {{.HostConfig.NetworkMode}}'
```

## Authentication — the one missing piece

Nothing on the box stores a Tailscale auth key (searched `~/.hermes/profiles/*/.env`, `~/.config`,
`~/.local/share`, the docker daemon, user systemd units — see `VERIFICATION.md`: no live key
exists; the only `tskey-` matches are documentation). So the node comes up but stays **Logged out**
until a key is supplied.

**Create the key:** Tailscale admin console → **Settings → Keys → Generate auth key.**

| Option | Recommendation |
|---|---|
| **Reusable** | **Yes.** The node rejoins after a container restart without a new key. |
| **Ephemeral** | **No.** An ephemeral node is deleted when it goes offline, so the device name and its ACL entry would not survive. |
| **Pre-approved** | Yes (skips device approval if you have that on). |
| **Tags** | Optional. See the caveat below. |

**Then run the one command:** the `TS_AUTHKEY=... docker compose ... up -d` line above.

Alternative without putting the key in the environment/history: write it to a file and use
`tailscale up`'s `file:` form — set `TS_EXTRA_ARGS="--auth-key=file:/run/secrets/kos.key"` and mount
the file read-only. (The in-image `tailscale up --help` documents `--auth-key value; if it begins
with "file:", then it's a path to a file containing the authkey`.)

### ACL caveat (the other, separate console action)

The node you create is owned by **you (liamdev631@)**, i.e. a tailnet *member* — unless you tag it.
The tailnet policy today is default **allow-all**, which is why a shared user can reach every
service on `beelink`. Two things are needed in **Access controls**:

1. Narrow the broad rule so it no longer covers outside users
   (`src: ["*"]` → `src: ["autogroup:member"]` — see `hermes-share/ACL-kingdom.md`).
2. Add exactly one rule so the shared user reaches **only the game node**:

   ```json
   { "action": "accept", "src": ["autogroup:shared"], "dst": ["kos-node.tail96c9e1.ts.net:443"] }
   ```

   If you instead attach a tag to the auth key (e.g. `--advertise-tags=tag:kos-node`), use
   `"src": ["autogroup:shared"], "dst": ["tag:kos-node:443"]` — a **tagged** node is not a member,
   so member rules do not apply to it and it needs its own rule either way.

   Robby then reaches `https://kos-node.tail96c9e1.ts.net/` and nothing else on `beelink`.

## What a tailnet peer (Robby) can reach

- **Only** the game surface: `https://kos-node.tail96c9e1.ts.net/` → the MCP server (once the ACL
  above is in place).
- The container exposes **no host port** and runs **no proxy** to anything else, so its existence
  does not widen what a peer can reach on `beelink`. The host's own exposure to Robby is unchanged
  by this container and is fixed by the ACL step above.

The world files (`/home/liamb/kos-world`) and the MCP script live on disk and are only exposed
*through* the MCP tool surface — a peer reads game state and queues commands via the tools, never by
browsing the host filesystem.

## Two honest limitations

1. **The container can reach the host's services.** On a Docker bridge the host is the container's
   gateway, so from inside the box `100.102.189.126:9119/8642/9120/9121`, the host's `0.0.0.0`
   ports and so on are reachable (proved in `VERIFICATION.md`). This is **not** a path Robby can use
   — the box runs no forwarding — but it means the box is not network-isolated *from the host*.
   Closing it needs a root firewall rule the operator can add once:

   ```bash
   sudo iptables -I DOCKER-USER -i br-$(docker network inspect kosnet -f '{{.Id}}' | cut -c1-12) \
        -o br-$(docker network inspect kosnet -f '{{.Id}}' | cut -c1-12) \
        -m addrtype --dst-type LOCAL -j REJECT
   ```

   (or bind the host services to `127.0.0.1` instead of the tailnet IP — the real fix, since a peer
   does not need them either).

2. **Do not add `security_opt: no-new-privileges:true`.** On this snap-packaged Docker it makes
   *every* exec fail with `operation not permitted` (verified) — the container cannot even start.
   `cap_drop: ALL` + read-only root are used instead.

## The game surface itself

`kos_mcp.py` is the project's own MCP server, unmodified. The container installs `mcp==2.3.0` (the
version in `kingdom/.venv`) and serves it over streamable-HTTP. Environment inside the box:
`KOS_WORLD_DIR=/kos-world`, `KOS_AGENT=kos-node`, and optionally `KOS_MCP_READONLY=1` to expose a
look-but-do-not-touch surface.
