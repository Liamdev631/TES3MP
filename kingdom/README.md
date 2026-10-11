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

## Tests

```bash
python3 -m unittest discover -s kingdom/auth -v        # 21 tests: hashing, lockouts, audit chain
kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_auth.lua   # 46: the login gate
```

Both run without root, without tailscale and without any game data — the identity lookup is
injected. `kingdom/tools/lua-5.1/` is the same Lua version the engine embeds, so the gate is
tested on the runtime it will actually use.

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
