# Where our scripts attach to the TES3MP server

The server ships with CoreScripts (found inside the release tarball at
`server/server/scripts/`), which is the Lua that implements chat, accounts, saving and most game
mechanics. Our scripts do not replace it — they extend it at the points it documents for extension,
and take over the one decision we care about: who a player is.

These are the real attachment points, read out of the shipped 0.8.1 CoreScripts:

| What | Where | Why it matters to us |
|---|---|---|
| Custom script loading | `scripts/customScripts.lua` — `require("custom/yourScript")` | the only place our scripts need to be registered; `scripts/custom/` is empty and waiting |
| First connect | `scripts/eventHandler.lua:427` `eventHandler.OnPlayerConnect(pid, playerName)` | where the tailnet identity is resolved and a password minted or asked for |
| Custom hooks | `scripts/customEventHooks.lua` — `triggerValidators` / `triggerHandlers` | CoreScripts' own documented way to participate in an event without editing its files |
| Login prompt | `scripts/guiHelper.lua:7` `ShowLogin` → `tes3mp.PasswordDialog(pid, guiHelper.ID.LOGIN, …)` | the password arrives as a GUI action, not a chat message |
| Registration prompt | `scripts/guiHelper.lua:11` `ShowRegister` → `PasswordDialog(pid, guiHelper.ID.REGISTER, …)` | the stock flow lets a player *choose* a password; we mint one instead |
| Submitted password | `scripts/eventHandler.lua:610` `eventHandler.OnGUIAction(pid, idGui, data)` | where our verification has to run instead of the stock database lookup |
| Stock accounts | `scripts/database.lua` (`SavePlayer`/`LoadPlayer`, tables) | a second credential store we do not want as the authority |
| Saving | `scripts/database.lua` `SavePlayer` / `SaveWorld` | how per-identity saves are written; the save name comes from our gate |
| Console | `scripts/config.lua` `config.allowConsole = false` | off by default; our camera drone needs it on for its own account |
| Menus | `scripts/menu/` (e.g. `defaultCrafting.lua`, `help.lua`) | the pattern to copy if we add our own in-game panel |

## What the wiring will be

1. `scripts/customScripts.lua` gains one line: `require("custom/kingdom")`.
2. `scripts/custom/kingdom.lua` requires our `kingdom_auth.lua` (already written and tested) and
   adapts it to CoreScripts:
   * `OnPlayerConnect` → resolve the tailnet identity from `GetIP(pid)`; if the identity is not on the
     guest list, kick; if it has no account, mint a password and show it once; otherwise ask for it.
   * the LOGIN GUI action → verify against the auth service instead of the stock database.
   * the REGISTER flow → left in place but not authoritative: a player who registers there still
     cannot get past our gate.
3. The save name is set from the identity (the `saveNames` table in `kingdom_auth.lua`), so the
   per-player state CoreScripts writes is keyed to the person, not to a typed character name.

## Honest status

This is designed against the shipped source, with the attachment points above verified by reading it —
but **not yet exercised in a running game**, because the world has no Morrowind data files yet. The
things to check the first time it runs, in order:

1. that `require("custom/kingdom")` loads without error and our hooks fire (the server log prints
   `[kingdom]` lines);
2. that a first connection mints a password and shows it once, and that the same identity is *not*
   offered a new one on reconnect;
3. that a wrong password is refused, counted, and eventually kicks — and that a correct one gets the
   player in with their own save;
4. that a device whose tailnet user id is not on the guest list is refused before any account exists.

Until step 1 passes, our gate is a tested library and not yet a gate.
