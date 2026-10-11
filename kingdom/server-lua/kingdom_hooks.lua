--[[ Kingdom of Science — the wiring between our logic and CoreScripts.

    The engine loads `scripts/serverCore.lua`, which requires `customScripts.lua`, and CoreScripts
    exposes `customEventHooks` for anything else that wants to take part in an event:

        customEventHooks.registerHandler("OnPlayerFinishLogin", function(eventStatus, pid) ... end)

    This file is the only place that touches that system. Our modules keep their logic and are called
    from here — defining the `On*` globals directly (the obvious approach, and the one we started
    with) collides with CoreScripts' own handlers for the same events, and one side loses silently.

    Which events we take, and why:

        OnPlayerConnect          the gate: who is this, is it one of us, does it have a password
        OnPlayerSendMessage      the login command, and holding chat until someone is in
        OnPlayerDisconnect       forget them
        OnPlayerFinishLogin      after CoreScripts' own login, drain the queue and publish state
        OnServerPostInit         the world is up: drain and publish
        OnServerExit             last chance to publish and not lose the queue
        OnCellLoad               players moving around: keep the state fresh
        OnPlayerCellChange       same
        OnObjectLoopTimeExpiration   CoreScripts' periodic event — the tick the engine itself lacks

    Tests: kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_hooks.lua
]]

local Hooks = {}

--- Load-time probe. This file is required by CoreScripts, whose loader swallows errors, so the only
--- way to tell "never loaded" from "loaded and then failed" is to write something down immediately.
do
    local world = (os.getenv and os.getenv("KOS_WORLD_DIR")) or "/home/liamb/kos-world"
    local probe = io.open(world .. "/hooks-loaded.txt", "w")
    if probe then
        probe:write("kingdom_hooks.lua was loaded at " .. tostring(os.date and os.date("%H:%M:%S") or "?") .. "\n")
        probe:close()
    end
end

Hooks.events = {
    "OnPlayerConnect", "OnPlayerSendMessage", "OnPlayerDisconnect", "OnPlayerFinishLogin",
    "OnServerPostInit", "OnServerExit", "OnCellLoad", "OnPlayerCellChange",
    "OnObjectLoopTimeExpiration",
}

--- Load a module whether it sits beside us or under custom/. The deployed layout puts everything in
--- scripts/custom/, and CoreScripts requires by name, so both forms have to work.
local function requireModule(name)
    local ok, module = pcall(require, name)
    if ok and type(module) == "table" then return module end
    local okCustom, moduleCustom = pcall(require, "custom." .. name)
    if okCustom and type(moduleCustom) == "table" then return moduleCustom end
    return nil, module
end

function Hooks.load()
    local Flags, flagsProblem = requireModule("kingdom_flags")
    local Kingdom, kingdomProblem = requireModule("kingdom_auth")
    local Bridge, bridgeProblem = requireModule("kingdom_bridge")
    if not (Flags and Kingdom and Bridge) then
        error("kingdom: a module failed to load — flags=" .. tostring(Flags) ..
              " auth=" .. tostring(Kingdom) .. " bridge=" .. tostring(Bridge) ..
              " (" .. tostring(flagsProblem) .. " / " .. tostring(kingdomProblem) ..
              " / " .. tostring(bridgeProblem) .. ")")
    end
    return { Flags = Flags, Kingdom = Kingdom, Bridge = Bridge }
end

--- Logging that actually reaches the server's log. CoreScripts uses `tes3mp.LogMessage`, and Lua's
--- plain `print` is not captured — which is how a silent failure went unnoticed the first time.
local function engineLog(message)
    local text = "[kingdom] " .. tostring(message)
    if type(tes3mp) == "table" and type(tes3mp.LogMessage) == "function"
        and type(enumerations) == "table" and enumerations.log then
        return tes3mp.LogMessage(enumerations.log.INFO, text)
    end
    return print(text)
end

--- Register everything. `hooks` is `customEventHooks` in the game and a stub in tests.
function Hooks.install(hooks, modules, logger)
    local log = logger or engineLog
    local loaded = modules or Hooks.load()
    local Kingdom, Bridge = loaded.Kingdom, loaded.Bridge

    -- Let the modules log where we can see it too.
    if type(Bridge.setDependencies) == "function" then Bridge.setDependencies({ log = log }) end
    if type(loaded.Flags) == "table" and type(loaded.Flags.setDependencies) == "function" then
        loaded.Flags.setDependencies({ log = log })
    end

    hooks.registerHandler("OnPlayerConnect", function(eventStatus, pid)
        -- The gate does its own kicking: a validator would silently skip CoreScripts' handler, and
        -- we want the reason to reach the player.
        local ok, problem = pcall(Kingdom.onPlayerConnect, pid)
        if not ok then log("OnPlayerConnect failed: " .. tostring(problem)) end
        Bridge.tick()
    end)

    hooks.registerHandler("OnPlayerSendMessage", function(eventStatus, pid, message)
        local consumed = false
        local ok, result = pcall(Kingdom.onPlayerSendMessage, pid, message)
        if ok then consumed = result
        else log("OnPlayerSendMessage failed: " .. tostring(result)) end
        if consumed then
            -- swallow it: an unauthenticated player's words do not reach the room
            return false
        end
        return true
    end)

    hooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
        pcall(Kingdom.onPlayerDisconnect, pid)
        Bridge.tick()
    end)

    hooks.registerHandler("OnPlayerFinishLogin", function(eventStatus, pid)
        local who = Kingdom.who(pid)
        log((who and (who.display or who.user_id) or tostring(pid)) .. " is in")
        Bridge.tick()
    end)

    hooks.registerHandler("OnServerPostInit", function(eventStatus)
        log("world up: flags " .. loaded.Flags.liveSummary())
        Bridge.tick()
    end)

    hooks.registerHandler("OnServerExit", function(eventStatus)
        Bridge.onServerExit()
    end)

    for pad, event in ipairs({ "OnCellLoad", "OnPlayerCellChange" }) do
        hooks.registerHandler(event, function(eventStatus, pid)
            Bridge.tick()
        end)
    end

    -- CoreScripts' loop event fires constantly, so this is rate limited: ticking on every one of
    -- them flooded the log and eventually overflowed the Lua stack (found by running it).
    local lastTick = 0
    hooks.registerHandler("OnObjectLoopTimeExpiration", function(eventStatus)
        local now = os.time()
        if now - lastTick < 1 then return end
        lastTick = now
        local ok, problem = pcall(Bridge.tick)
        if not ok then log("tick failed: " .. tostring(problem)) end
    end)

    log("hooks installed: " .. #Hooks.events .. " events")
    return true
end

-- In the game there is exactly one of these; outside it, nothing happens until install is called.
-- Say so either way: a silent no-op here is how the first attempt looked like it had worked.
if type(customEventHooks) ~= "table" then
    pcall(require, "customEventHooks")   -- CoreScripts' module sets the global as a side effect
end
if type(customEventHooks) == "table" then
    local ok, problem = pcall(Hooks.install, customEventHooks)
    if not ok then engineLog("FAILED to install hooks: " .. tostring(problem)) end
else
    engineLog("no customEventHooks available — hooks not installed")
end

return Hooks
