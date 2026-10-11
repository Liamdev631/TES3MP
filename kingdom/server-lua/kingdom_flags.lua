--[[ Kingdom of Science — feature flags.

    Every experiment in this world is off until someone turns it on by name, in a file. That is the
    whole point: a half-finished idea can sit in the running server — compiled, loaded, reachable —
    without being able to affect a session, and turning it on or off never means editing code.

    The rules, in order of precedence:

      1. a flag that is not listed in `Flags.known` is always off, even if the file says otherwise —
         so a typo, a stale file or a malicious edit cannot switch on behaviour that does not exist;
      2. the master switch `experiments` overrides everything: with it off, no `exp_` flag is live;
      3. otherwise a flag is on only if the file sets it to true.

    The file lives outside the shared folder, in the same place as the queue and the saves, and every
    applied command is logged with the flag state that produced it — so when something looks wrong,
    the log says which combination was live.

    Tests:  kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_flags.lua
]]

local json = require("kingdom_json")

local Flags = {}

Flags.path = ((os.getenv and os.getenv("KOS_FLAGS_FILE"))
    or (((os.getenv and os.getenv("KOS_WORLD_DIR")) or "/home/liamb/kos-world") .. "/flags.json"))

--- Every flag this world understands, with what it does. Anything absent from this table is off and
--- stays off; adding a flag is a deliberate act, not an accident of a config file.
---
--- Two classes:
---   * baseline capabilities — what the world is for, on unless someone turns them off;
---   * experiments (`exp_`) — off unless the master switch is on *and* the flag is named, so a
---     half-finished idea can live in the running server without being able to touch a session.
Flags.known = {
    -- master switch: `exp_` flags are inert while this is false
    experiments = "master switch for every experimental feature",
    -- baseline: the things the world exists to do
    world_edits = "allow agent world edits at all (queue drain)",
    weather_control = "let agents set the weather and the clock",
    avatar_control = "let agents move a player's avatar and change its stats or model",
    screenshots = "let agents request in-game screenshots",
    world_speech = "let agents speak in the world's voice",
    -- experiments: off until named, and inert unless `experiments` is on
    exp_custom_models = "let agents define new object types pointing at model files",
    exp_npc_control = "let agents move, heal and kill NPCs",
    exp_console = "let agents run raw console commands on a client",
    exp_scheduled_weather = "let agents drive weather on a schedule rather than on request",
    exp_player_remodel = "let agents change what a player looks like while they play",
    exp_hot_reload = "reload the server's Lua when the files change, without a full restart",
}

--- Flags whose name starts with this are governed by the master switch.
local EXPERIMENT_PREFIX = "exp_"

local deps = {
    read = function(path)
        local handle = io.open(path, "r")
        if not handle then return nil end
        local body = handle:read("*a")
        handle:close()
        return body
    end,
    log = function(message) print("[kingdom/flags] " .. tostring(message)) end,
}

local cache = nil

function Flags.setDependencies(replacement)
    for key, value in pairs(replacement) do deps[key] = value end
    cache = nil
end

--- Forget the cached file so the next question re-reads it. The server calls this on every event, so
--- flipping a flag in the file takes effect within one game event, not one restart.
function Flags.reload()
    cache = nil
    return Flags.raw()
end

function Flags.raw()
    if cache ~= nil then return cache end
    local body = deps.read(Flags.path)
    if not body then
        cache = {}
        return cache
    end
    local decoded = json.decode(body)
    if type(decoded) ~= "table" then
        deps.log("flags.json could not be read; treating every flag as off")
        cache = {}
        return cache
    end
    cache = decoded
    return cache
end

function Flags.isKnown(name)
    return Flags.known[name] ~= nil
end

--- Is this feature live right now? Asked constantly, so it must be cheap and it must default to no.
function Flags.enabled(name)
    if not Flags.isKnown(name) then return false end
    local raw = Flags.raw()
    local experiments = raw.experiments == true
    if name ~= "experiments" and name:sub(1, #EXPERIMENT_PREFIX) == EXPERIMENT_PREFIX and not experiments then
        return false
    end
    return raw[name] == true
end

--- The current state of everything, for status output and for the record on each applied command.
function Flags.all()
    local state = {}
    for name in pairs(Flags.known) do
        state[name] = Flags.enabled(name)
    end
    return state
end

--- A short string naming the live experiment flags, for log lines that must stay readable.
function Flags.liveSummary()
    local live = {}
    for name in pairs(Flags.known) do
        if name ~= "experiments" and Flags.enabled(name) then live[#live + 1] = name end
    end
    table.sort(live)
    if #live == 0 then return "none" end
    return table.concat(live, ",")
end

return Flags
