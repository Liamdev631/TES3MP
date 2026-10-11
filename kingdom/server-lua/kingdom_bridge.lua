--[[ Kingdom of Science — the agent bridge.

    Agents do not talk to the game. They leave commands in a queue; this script picks them up on the
    next engine event and turns each one into calls the fork already exposes. Everything an agent can
    ask for is in `actions`, every engine call goes through `deps.engine`, and every attempt is
    written to an append-only log with the agent's name on it.

    Two rules that make it safe to leave running while two people are playing:

      * only cells on the allow-list may be touched, so no agent can quietly rearrange the world's
        main quest areas;
      * a command that cannot be applied (bad cell, unknown action, malformed JSON) is left in the
        queue and reported, never silently dropped or half-applied.

    The engine has no timer callback, so `drain` is called from the events the server already
    receives (connect, cell change, object spawn, message, post-init) — see the hooks at the bottom.

    Test without a game:  kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_bridge.lua
]]

local json = require("kingdom_json")
local Flags = require("kingdom_flags")

local Bridge = {}

Bridge.config = {
    queuePath = "/home/liamb/kos-world/queue.jsonl",
    appliedPath = "/home/liamb/kos-world/applied.jsonl",
    statePath = "/home/liamb/kos-world/world-state.json",
    screenshotDir = "/home/liamb/kos-world/screenshots",
    --- Cells agents may edit. Anything else is refused and reported.
    allowedCells = {
        ["Balmora, Council Club"] = true,
        ["Seyda Neen, Arrille's Tradehouse"] = true,
        ["Kingdom Workshop"] = true,
    },
    maxPerDrain = 25,
}

-- Every engine call the bridge can make, in one place so tests can watch it.
local function engineCalls()
    return {
        InitializeObjectList = InitializeObjectList,
        SetObjectListPid = SetObjectListPid,
        SetObjectListCell = SetObjectListCell,
        SetObjectListAction = SetObjectListAction,
        SetObjectRefId = SetObjectRefId,
        SetObjectCount = SetObjectCount,
        SetObjectMpNum = SetObjectMpNum,
        SetObjectPosition = SetObjectPosition,
        SetObjectRotation = SetObjectRotation,
        SetObjectScale = SetObjectScale,
        AddObject = AddObject,
        SendObjectPlace = SendObjectPlace,
        SendObjectSpawn = SendObjectSpawn,
        SendObjectMove = SendObjectMove,
        SendObjectRotate = SendObjectRotate,
        SendObjectScale = SendObjectScale,
        SendObjectDelete = SendObjectDelete,
        SetObjectListConsoleCommand = SetObjectListConsoleCommand,
        SendConsoleCommand = SendConsoleCommand,
        ClearRecords = ClearRecords,
        SetRecordType = SetRecordType,
        SetRecordId = SetRecordId,
        SetRecordModel = SetRecordModel,
        SetRecordName = SetRecordName,
        SetRecordScale = SetRecordScale,
        AddRecord = AddRecord,
        SendRecordDynamic = SendRecordDynamic,
        GetName = GetName,
        GetCell = GetCell,
        GetPosX = GetPosX,
        GetPosY = GetPosY,
        GetPosZ = GetPosZ,
        SetWeatherRegion = SetWeatherRegion,
        SetWeatherForceState = SetWeatherForceState,
        SetWeatherCurrent = SetWeatherCurrent,
        SetWeatherNext = SetWeatherNext,
        SetWeatherQueued = SetWeatherQueued,
        SetWeatherTransitionFactor = SetWeatherTransitionFactor,
        SendWorldWeather = SendWorldWeather,
        SetHour = SetHour,
        SetDay = SetDay,
        SetMonth = SetMonth,
        SetYear = SetYear,
        SetDaysPassed = SetDaysPassed,
        SetTimeScale = SetTimeScale,
        SendWorldTime = SendWorldTime,
        SetActorListPid = SetActorListPid,
        SetActorListCell = SetActorListCell,
        SetActorListAction = SetActorListAction,
        SetActorRefId = SetActorRefId,
        SetActorMpNum = SetActorMpNum,
        SetActorPosition = SetActorPosition,
        SetActorRotation = SetActorRotation,
        SetActorHealthCurrent = SetActorHealthCurrent,
        SetActorDeathState = SetActorDeathState,
        SendActorPosition = SendActorPosition,
        SendActorStatsDynamic = SendActorStatsDynamic,
        SendActorDeath = SendActorDeath,
        SetCell = SetCell,
        SetPos = SetPos,
        SetRot = SetRot,
        SendCell = SendCell,
        SendPos = SendPos,
        SetModel = SetModel,
        SendBaseInfo = SendBaseInfo,
        SetHealthCurrent = SetHealthCurrent,
        SetLevel = SetLevel,
        SetName = SetName,
        SendStatsDynamic = SendStatsDynamic,
        SendMessage = SendMessage,
        GetPlayers = function()
            local pids = {}
            for pid = 0, 63 do
                if Player(pid) ~= nil or (GetPlayerName and GetPlayerName(pid) ~= "") then
                    pids[#pids + 1] = pid
                end
            end
            return pids
        end,
    }
end

local deps = {
    engine = engineCalls(),
    readLines = function(path)
        local handle = io.open(path, "r")
        if not handle then return {} end
        local lines = {}
        for line in handle:lines() do lines[#lines + 1] = line end
        handle:close()
        return lines
    end,
    writeLines = function(path, lines)
        local handle = io.open(path, "w")
        if not handle then return false end
        for _, line in ipairs(lines) do handle:write(line, "\n") end
        handle:close()
        return true
    end,
    appendLine = function(path, line)
        local handle = io.open(path, "a")
        if not handle then return false end
        handle:write(line, "\n")
        handle:close()
        return true
    end,
    log = function(message) print("[kingdom] " .. tostring(message)) end,
    now = function() return os.time() end,
}

function Bridge.setDependencies(replacement)
    for key, value in pairs(replacement) do deps[key] = value end
end

function Bridge.dependencies()
    return deps
end

--------------------------------------------------------------------------- helpers

local function cellAllowed(cell)
    return cell ~= nil and Bridge.config.allowedCells[cell] == true
end

local function objectList(cell, action)
    deps.engine.InitializeObjectList()
    deps.engine.SetObjectListCell(cell)
    deps.engine.SetObjectListAction(action)
end

--------------------------------------------------------------------------- actions

--- Each action receives a decoded command and performs engine calls. They return true, or
--- false plus a human-readable reason that goes back to the agent and into the applied log.
Bridge.actions = {}

Bridge.actions.spawn_object = function(command)
    if not command.refId then return false, "spawn_object needs refId" end
    local cell = command.cell
    local position = command.position or { 0, 0, 0 }
    objectList(cell, 1)                                  -- ADD
    deps.engine.SetObjectRefId(command.refId)
    deps.engine.SetObjectCount(command.count or 1)
    deps.engine.SetObjectPosition(position[1] or 0, position[2] or 0, position[3] or 0)
    if command.rotation then
        deps.engine.SetObjectRotation(command.rotation[1] or 0, command.rotation[2] or 0,
                                      command.rotation[3] or 0)
    end
    if command.scale then deps.engine.SetObjectScale(command.scale) end
    deps.engine.AddObject()
    deps.engine.SendObjectSpawn(true, false)
    return true
end

--- Define a brand-new object type pointing at a model we supply, then push the record to every
--- client. This is the "swap a model" primitive: the model path is a file the players' data
--- folders must already carry.
Bridge.actions.define_record = function(command)
    if not command.recordId then return false, "define_record needs recordId" end
    if not command.model then return false, "define_record needs model" end
    deps.engine.ClearRecords()
    deps.engine.SetRecordType(command.recordType or 0)    -- 0 = object by default
    deps.engine.SetRecordId(command.recordId)
    deps.engine.SetRecordModel(command.model)
    if command.name then deps.engine.SetRecordName(command.name) end
    if command.scale then deps.engine.SetRecordScale(command.scale) end
    deps.engine.AddRecord()
    for _, pid in ipairs(command.pids or deps.engine.GetPlayers()) do
        deps.engine.SendRecordDynamic(pid, true, false)
    end
    return true
end

Bridge.actions.delete_object = function(command)
    if not command.mpNum then return false, "delete_object needs mpNum" end
    objectList(command.cell, 2)                          -- REMOVE
    deps.engine.SetObjectMpNum(command.mpNum)
    deps.engine.AddObject()
    deps.engine.SendObjectDelete(true, false)
    return true
end

Bridge.actions.move_object = function(command)
    if not command.mpNum then return false, "move_object needs mpNum" end
    local position = command.position or {}
    if position[1] then
        objectList(command.cell, 0)                      -- SET
        deps.engine.SetObjectMpNum(command.mpNum)
        deps.engine.SetObjectPosition(position[1], position[2] or 0, position[3] or 0)
        deps.engine.AddObject()
        deps.engine.SendObjectMove(true, false)
    end
    if command.rotation then
        objectList(command.cell, 0)
        deps.engine.SetObjectMpNum(command.mpNum)
        deps.engine.SetObjectRotation(command.rotation[1] or 0, command.rotation[2] or 0,
                                      command.rotation[3] or 0)
        deps.engine.AddObject()
        deps.engine.SendObjectRotate(true, false)
    end
    if not position[1] and not command.rotation then
        return false, "move_object needs a position or a rotation"
    end
    return true
end

Bridge.actions.scale_object = function(command)
    if not command.mpNum then return false, "scale_object needs mpNum" end
    if not command.scale then return false, "scale_object needs scale" end
    objectList(command.cell, 0)
    deps.engine.SetObjectMpNum(command.mpNum)
    deps.engine.SetObjectScale(command.scale)
    deps.engine.AddObject()
    deps.engine.SendObjectScale(true, false)
    return true
end

--- Put a chosen client somewhere and run a console command on it. This is the camera drone's
--- steering wheel: aim the drone, then ask for a picture.
Bridge.actions.console = function(command)
    if not command.command then return false, "console needs command" end
    if command.cell and not cellAllowed(command.cell) then
        return false, "cell is not on the allow-list: " .. tostring(command.cell)
    end
    objectList(command.cell, 0)
    deps.engine.SetObjectListConsoleCommand(command.command)
    for _, pid in ipairs(command.pids or deps.engine.GetPlayers()) do
        deps.engine.SetObjectListPid(pid)
        deps.engine.SendConsoleCommand(false, false)
    end
    return true
end

--- A screenshot is not an engine call we have yet: the bridge records the request, and the capture
--- helper running outside the game positions the drone and grabs the frame.
Bridge.actions.screenshot = function(command)
    local target = command.filename or ("shot-" .. tostring(deps.now()) .. ".png")
    local request = {
        id = command.id,
        cell = command.cell,
        position = command.position,
        rotation = command.rotation,
        filename = target,
        agent = command.agent,
    }
    local path = Bridge.config.screenshotDir .. "/" .. target:gsub("%.png$", "") .. ".json"
    if not deps.writeLines(path, { json.encode(request) }) then
        return false, "could not write the screenshot request to " .. path
    end
    return true
end

--- Weather and time belong to the world, so they are sent to every player rather than attached to one.
Bridge.actions.set_weather = function(command)
    if not command.weather then return false, "set_weather needs weather" end
    if command.region then deps.engine.SetWeatherRegion(command.region) end
    deps.engine.SetWeatherForceState(command.force ~= false)
    deps.engine.SetWeatherCurrent(command.weather)
    if command.next then deps.engine.SetWeatherNext(command.next) end
    if command.queued then deps.engine.SetWeatherQueued(command.queued) end
    if command.transition then deps.engine.SetWeatherTransitionFactor(command.transition) end
    for _, pid in ipairs(deps.engine.GetPlayers()) do
        deps.engine.SendWorldWeather(pid, true, false)
    end
    return true
end

Bridge.actions.set_time = function(command)
    if command.hour then deps.engine.SetHour(command.hour) end
    if command.day then deps.engine.SetDay(command.day) end
    if command.month then deps.engine.SetMonth(command.month) end
    if command.year then deps.engine.SetYear(command.year) end
    if command.daysPassed then deps.engine.SetDaysPassed(command.daysPassed) end
    if command.timeScale then deps.engine.SetTimeScale(command.timeScale) end
    if not (command.hour or command.day or command.month or command.year or command.daysPassed or command.timeScale) then
        return false, "set_time needs at least one of hour, day, month, year, daysPassed, timeScale"
    end
    for _, pid in ipairs(deps.engine.GetPlayers()) do
        deps.engine.SendWorldTime(pid, true, false)
    end
    return true
end

--- An NPC is addressed by its mpNum (the id the server gave it) or by refId in a cell.
Bridge.actions.move_actor = function(command)
    if not command.mpNum and not command.refId then
        return false, "move_actor needs mpNum or refId"
    end
    local position = command.position or {}
    deps.engine.SetActorListCell(command.cell)
    deps.engine.SetActorListAction(0)
    if command.mpNum then deps.engine.SetActorMpNum(command.mpNum)
    else deps.engine.SetActorRefId(command.refId) end
    if position[1] then deps.engine.SetActorPosition(position[1], position[2] or 0, position[3] or 0) end
    if command.rotation then
        deps.engine.SetActorRotation(command.rotation[1] or 0, command.rotation[2] or 0)
    end
    for _, pid in ipairs(deps.engine.GetPlayers()) do
        deps.engine.SetActorListPid(pid)
        deps.engine.SendActorPosition(true, false)
    end
    return true
end

Bridge.actions.set_actor_health = function(command)
    if not command.health then return false, "set_actor_health needs health" end
    if not command.mpNum and not command.refId then
        return false, "set_actor_health needs mpNum or refId"
    end
    deps.engine.SetActorListCell(command.cell)
    deps.engine.SetActorListAction(0)
    if command.mpNum then deps.engine.SetActorMpNum(command.mpNum)
    else deps.engine.SetActorRefId(command.refId) end
    deps.engine.SetActorHealthCurrent(command.health)
    for _, pid in ipairs(deps.engine.GetPlayers()) do
        deps.engine.SetActorListPid(pid)
        deps.engine.SendActorStatsDynamic(true, false)
    end
    return true
end

--- Death state is a number in the engine (1 dead, 0 alive), so `resurrect` is its own flag.
Bridge.actions.kill_actor = function(command)
    if not command.mpNum and not command.refId then return false, "kill_actor needs mpNum or refId" end
    deps.engine.SetActorListCell(command.cell)
    deps.engine.SetActorListAction(0)
    if command.mpNum then deps.engine.SetActorMpNum(command.mpNum)
    else deps.engine.SetActorRefId(command.refId) end
    deps.engine.SetActorDeathState(command.resurrect and 0 or 1)
    for _, pid in ipairs(deps.engine.GetPlayers()) do
        deps.engine.SetActorListPid(pid)
        deps.engine.SendActorDeath(true, false)
    end
    return true
end

--- Move a player's own avatar: the pid is theirs, so this works on the person who asked for it.
Bridge.actions.teleport_player = function(command)
    if not command.pid then return false, "teleport_player needs pid" end
    if command.cell then deps.engine.SetCell(command.pid, command.cell) end
    local position = command.position
    if position and position[1] then
        deps.engine.SetPos(command.pid, position[1], position[2] or 0, position[3] or 0)
    end
    if command.rotation then
        deps.engine.SetRot(command.pid, command.rotation[1] or 0, command.rotation[2] or 0)
    end
    if not command.cell and not position then
        return false, "teleport_player needs a cell or a position"
    end
    if command.cell then deps.engine.SendCell(command.pid) end
    if position and position[1] then deps.engine.SendPos(command.pid) end
    return true
end

--- Swap what a player looks like: the model is a mesh file their data folder must already carry.
Bridge.actions.set_player_model = function(command)
    if not command.pid then return false, "set_player_model needs pid" end
    if not command.model then return false, "set_player_model needs model" end
    deps.engine.SetModel(command.pid, command.model)
    deps.engine.SendBaseInfo(command.pid)
    return true
end

Bridge.actions.set_player_stats = function(command)
    if not command.pid then return false, "set_player_stats needs pid" end
    if command.health then deps.engine.SetHealthCurrent(command.pid, command.health) end
    if command.level then deps.engine.SetLevel(command.pid, command.level) end
    if command.name then deps.engine.SetName(command.pid, command.name) end
    if not (command.health or command.level or command.name) then
        return false, "set_player_stats needs health, level or name"
    end
    deps.engine.SendStatsDynamic(command.pid)
    return true
end

--- Speak as the world.
Bridge.actions.say = function(command)
    if not command.message then return false, "say needs a message" end
    for _, pid in ipairs(command.pids or deps.engine.GetPlayers()) do
        deps.engine.SendMessage(pid, command.message, true, false)
    end
    return true
end

--------------------------------------------------------------------------- the queue

--- Which flag has to be live for which action. Checked in one place, so a feature cannot be
--- reachable by one path and hidden on another, and the refusal names the flag to switch on.
local ACTION_FLAG = {
    spawn_object = "world_edits",
    define_record = "exp_custom_models",
    delete_object = "world_edits",
    move_object = "world_edits",
    scale_object = "world_edits",
    set_weather = "weather_control",
    set_time = "weather_control",
    move_actor = "exp_npc_control",
    set_actor_health = "exp_npc_control",
    kill_actor = "exp_npc_control",
    teleport_player = "avatar_control",
    set_player_model = "exp_player_remodel",
    set_player_stats = "avatar_control",
    say = "world_speech",
    screenshot = "screenshots",
    console = "exp_console",
}

local function classify(source)
    local command, problem = json.decode(source)
    if not command then return nil, "unreadable command: " .. tostring(problem) end
    if not command.action then return nil, "command has no action" end
    if not Bridge.actions[command.action] then
        return nil, "unknown action: " .. tostring(command.action)
    end
    local flag = ACTION_FLAG[command.action]
    if flag and not Flags.enabled(flag) then
        return nil, "that feature is switched off: " .. flag
    end
    if not cellAllowed(command.cell) then
        return nil, "cell is not on the allow-list: " .. tostring(command.cell)
    end
    return command, nil
end

local function record(entry)
    entry.flags = entry.flags or Flags.liveSummary()
    deps.appendLine(Bridge.config.appliedPath, json.encode(entry))
end

--- Apply everything currently queued. Returns a small report, and leaves only the commands that
--- could not be applied in the queue.
function Bridge.drain()
    local report = { applied = 0, refused = 0 }
    -- Re-read the flag file here, so flipping a switch takes effect on the next game event rather
    -- than at the next restart.
    Flags.reload()
    if not Flags.enabled("world_edits") then
        report.world_edits = false
        return report
    end
    local lines = deps.readLines(Bridge.config.queuePath)
    if #lines == 0 then return report end

    local keep = {}
    for index, line in ipairs(lines) do
        if line:match("^%s*$") then
            -- blank lines are simply consumed
        elseif index > Bridge.config.maxPerDrain then
            keep[#keep + 1] = line                 -- too much at once: leave it for the next event
        else
            local command, problem = classify(line)
            if command then
                local ok, reason = Bridge.actions[command.action](command)
                record({
                    at = deps.now(), id = command.id, action = command.action, cell = command.cell,
                    agent = command.agent, ok = ok and true or false, reason = reason,
                })
                if ok then report.applied = report.applied + 1
                else
                    report.refused = report.refused + 1
                    keep[#keep + 1] = line
                    deps.log("refused " .. tostring(command.action) .. ": " .. tostring(reason))
                end
            else
                report.refused = report.refused + 1
                keep[#keep + 1] = line
                record({ at = deps.now(), at_line = line, ok = false, reason = problem })
                deps.log("refused a queued command: " .. tostring(problem))
            end
        end
    end
    deps.writeLines(Bridge.config.queuePath, keep)
    return report
end

function Bridge.reset()
    deps.engine = engineCalls()
end

--- The engine cannot answer a question, so we leave the answer where the agents can read it: this
--- is the file the MCP tools read for anything that is not a command.
function Bridge.snapshot()
    local players = {}
    for _, pid in ipairs(deps.engine.GetPlayers()) do
        players[#players + 1] = {
            pid = pid,
            name = deps.engine.GetName(pid),
            cell = deps.engine.GetCell(pid),
            position = { deps.engine.GetPosX(pid), deps.engine.GetPosY(pid), deps.engine.GetPosZ(pid) },
        }
    end
    local state = { at = deps.now(), players = players, queued = #deps.readLines(Bridge.config.queuePath) }
    deps.writeLines(Bridge.config.statePath, { json.encode(state) })
    return state
end

--------------------------------------------------------------------------- engine hooks

--- The engine has no timer, so both directions are driven by events it already sends us: pick up
--- whatever agents have asked for, then publish where everyone is.
local function tick()
    Bridge.drain()
    Bridge.snapshot()
end

function OnServerInit() tick() end
function OnServerPostInit() tick() end
function OnPlayerConnect(pid) tick() return true end
function OnPlayerCellChange(pid) tick() end
function OnObjectSpawn(pid) tick() end
function OnPlayerDisconnect(pid) tick() end

--- On the way out — the last event before a reload or a restart — make sure the world's state is
--- published and the queue is not silently lost. This is what makes an update safe to attempt.
function OnServerExit()
    local report = Bridge.drain()
    Bridge.snapshot()
    deps.log("closing: applied " .. tostring(report.applied) .. ", refused " .. tostring(report.refused))
end

function OnServerScriptCrash(message)
    deps.log("script error: " .. tostring(message))
end

return Bridge
