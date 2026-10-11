--[[ Tests for the agent bridge. Same runtime the engine embeds:

      kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_bridge.lua

    The engine is a stub that records the calls it receives, so what is verified here is exactly the
    sequence of calls a command turns into — the part that would otherwise only be discoverable by
    watching two people play.
]]

package.path = "./kingdom/server-lua/?.lua;" .. package.path
local json = require("kingdom_json")
local Flags = require("kingdom_flags")
local Bridge = dofile("kingdom/server-lua/kingdom_bridge.lua")

--- Everything on, unless a test says otherwise, so the action tests below exercise real behaviour.
--- (The bridge gates actions on flags; that gating has its own tests at the end of this file.)
local function flagsBody(overrides)
    local body = {
        experiments = true, world_edits = true, weather_control = true, avatar_control = true,
        screenshots = true, world_speech = true, exp_custom_models = true, exp_npc_control = true,
        exp_console = true, exp_player_remodel = true, exp_hot_reload = true,
    }
    for key, value in pairs(overrides or {}) do body[key] = value end
    return json.encode(body)
end

local passed, failed = 0, 0
local current = ""

local function check(condition, description)
    if condition then passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  FAIL  %s\n        %s", current, description))
    end
end

local function same(actual, expected, description)
    check(actual == expected, description .. " (expected " .. tostring(expected) ..
          ", got " .. tostring(actual) .. ")")
end

local calls, queueLines, appliedLines, filesWritten, fileContents, flagOverrides

local function setup()
    calls, queueLines, appliedLines, filesWritten, fileContents = {}, {}, {}, {}, {}
    flagOverrides = nil
    local engine = {}
    local names = { "InitializeObjectList", "SetObjectListPid", "SetObjectListCell",
                    "SetObjectListAction", "SetObjectRefId", "SetObjectCount", "SetObjectMpNum",
                    "SetObjectPosition", "SetObjectRotation", "SetObjectScale", "AddObject",
                    "SendObjectPlace", "SendObjectSpawn", "SendObjectMove", "SendObjectRotate",
                    "SendObjectScale", "SendObjectDelete", "SetObjectListConsoleCommand",
                    "SendConsoleCommand", "ClearRecords", "SetRecordType", "SetRecordId",
                    "SetRecordModel", "SetRecordName", "SetRecordScale", "AddRecord",
                    "SendRecordDynamic", "SetWeatherRegion", "SetWeatherForceState",
                    "SetWeatherCurrent", "SetWeatherNext", "SetWeatherQueued",
                    "SetWeatherTransitionFactor", "SendWorldWeather", "SetHour", "SetDay",
                    "SetMonth", "SetYear", "SetDaysPassed", "SetTimeScale", "SendWorldTime",
                    "SetActorListPid", "SetActorListCell", "SetActorListAction", "SetActorRefId",
                    "SetActorMpNum", "SetActorPosition", "SetActorRotation", "SetActorHealthCurrent",
                    "SetActorDeathState", "SendActorPosition", "SendActorStatsDynamic",
                    "SendActorDeath", "SetCell", "SetPos", "SetRot", "SendCell", "SendPos",
                    "SetModel", "SendBaseInfo", "SetHealthCurrent", "SetLevel", "SetName",
                    "SendStatsDynamic", "SendMessage" }
    for _, name in ipairs(names) do
        engine[name] = function(...)
            local args = { ... }
            local rendered = {}
            for index, value in ipairs(args) do
                rendered[index] = tostring(value)
            end
            calls[#calls + 1] = name .. "(" .. table.concat(rendered, ",") .. ")"
        end
    end
    engine.GetPlayers = function() return { 0, 1 } end
    engine.GetName = function(pid) return pid == 0 and "liam" or "robby" end
    engine.GetCell = function(pid) return "Kingdom Workshop" end
    engine.GetPosX = function(pid) return pid * 10 end
    engine.GetPosY = function() return 1 end
    engine.GetPosZ = function() return -5 end
    Bridge.setDependencies({
        engine = engine,
        readLines = function() return queueLines end,
        writeLines = function(path, lines)
            local copy = {}
            for _, line in ipairs(lines) do copy[#copy + 1] = line end
            fileContents[path] = copy
            filesWritten[#filesWritten + 1] = path
            if path == Bridge.config.queuePath then queueLines = copy end
            return true
        end,
        appendLine = function(path, line) appliedLines[#appliedLines + 1] = line return true end,
        log = function() end,
        now = function() return 1234 end,
    })
    Bridge.config.allowedCells = { ["Kingdom Workshop"] = true, ["Balmora, Council Club"] = true }
    Bridge.config.maxPerDrain = 25
    Flags.setDependencies({
        read = function() return flagsBody(flagOverrides) end,
        log = function() end,
    })
end

local function test(name, body)
    current = name
    setup()
    body()
end

local function joined()
    return table.concat(calls, " | ")
end

local function queue(...)
    for _, line in ipairs({ ... }) do queueLines[#queueLines + 1] = line end
end

--------------------------------------------------------------------------- json

test("json: decodes what our tooling writes", function()
    local decoded, problem = json.decode('{"action":"spawn_object","cell":"Kingdom Workshop","position":[1,-2.5,3]}')
    check(decoded ~= nil, "decoded: " .. tostring(problem))
    same(decoded.action, "spawn_object", "action")
    same(decoded.cell, "Kingdom Workshop", "cell")
    same(decoded.position[2], -2.5, "array of numbers")
    same(#decoded.position, 3, "array length")
end)

test("json: round trips deterministically", function()
    local text = json.encode({ action = "scale_object", scale = 2, mpNum = 7, agent = "worldsmith" })
    same(text, '{"action":"scale_object","agent":"worldsmith","mpNum":7,"scale":2}', "sorted keys")
    local back = json.decode(text)
    same(back.scale, 2, "numbers survive")
    same(back.mpNum, 7, "and so do ids")
end)

test("json: refuses rather than guessing", function()
    local decoded, problem = json.decode('{"a":"unterminated')
    check(decoded == nil and problem ~= nil, "unterminated string refused")
    decoded, problem = json.decode("not json")
    check(decoded == nil, "garbage refused")
end)

--------------------------------------------------------------------------- actions

test("spawn_object builds the object list then sends it to everyone", function()
    queue('{"id":"c1","action":"spawn_object","agent":"worldsmith","cell":"Kingdom Workshop",' ..
          '"refId":"kingdom_pillar","count":2,"position":[10,0,-4],"rotation":[0,1.5,0],"scale":1.5}')
    local report = Bridge.drain()
    same(report.applied, 1, "applied")
    same(report.refused, 0, "nothing refused")
    same(joined(),
        "InitializeObjectList() | SetObjectListCell(Kingdom Workshop) | SetObjectListAction(1) | " ..
        "SetObjectRefId(kingdom_pillar) | SetObjectCount(2) | SetObjectPosition(10,0,-4) | " ..
        "SetObjectRotation(0,1.5,0) | SetObjectScale(1.5) | AddObject() | SendObjectSpawn(true,false)",
        "the exact call sequence")
end)

test("define_record points a new object type at one of our models", function()
    queue('{"id":"c2","action":"define_record","agent":"artist","cell":"Kingdom Workshop",' ..
          '"recordId":"kingdom_sprite","model":"meshes/kos/sprite.nif","name":"Sprite","scale":0.5}')
    local report = Bridge.drain()
    same(report.applied, 1, "applied")
    same(joined(),
        "ClearRecords() | SetRecordType(0) | SetRecordId(kingdom_sprite) | " ..
        "SetRecordModel(meshes/kos/sprite.nif) | SetRecordName(Sprite) | SetRecordScale(0.5) | " ..
        "AddRecord() | SendRecordDynamic(0,true,false) | SendRecordDynamic(1,true,false)",
        "record pushed to every player")
end)

test("define_record without a model is refused", function()
    queue('{"id":"c3","action":"define_record","cell":"Kingdom Workshop","recordId":"x"}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    same(#calls, 0, "no engine call was made")
    check(table.concat(appliedLines, "\n"):find("needs model", 1, true) ~= nil, "reason is recorded")
end)

test("delete, move and scale address objects by mpNum", function()
    queue('{"id":"d1","action":"delete_object","cell":"Kingdom Workshop","mpNum":42}',
          '{"id":"d2","action":"move_object","cell":"Kingdom Workshop","mpNum":42,"position":[1,2,3]}',
          '{"id":"d3","action":"scale_object","cell":"Kingdom Workshop","mpNum":42,"scale":0.25}')
    local report = Bridge.drain()
    same(report.applied, 3, "all three applied")
    check(joined():find("SetObjectMpNum(42) | AddObject() | SendObjectDelete(true,false)", 1, true) ~= nil,
          "delete uses the REMOVE action")
    check(joined():find("SetObjectListAction(2)", 1, true) ~= nil, "remove action present")
    check(joined():find("SendObjectMove(true,false)", 1, true) ~= nil, "move sent")
    check(joined():find("SetObjectScale(0.25) | AddObject() | SendObjectScale(true,false)", 1, true) ~= nil,
          "scale sent")
end)

test("move_object needs something to move", function()
    queue('{"id":"d4","action":"move_object","cell":"Kingdom Workshop","mpNum":7}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    check(table.concat(appliedLines, "\n"):find("needs a position or a rotation", 1, true) ~= nil,
          "explains what was missing")
end)

test("console steers a client, and is refused outside the allow-list", function()
    queue('{"id":"e1","action":"console","cell":"Kingdom Workshop","command":"ToggleVanityMode"}')
    Bridge.drain()
    check(joined():find("SetObjectListConsoleCommand(ToggleVanityMode)", 1, true) ~= nil, "command queued")
    check(joined():find("SendConsoleCommand(false,false)", 1, true) ~= nil, "sent")

    setup()
    queue('{"id":"e2","action":"console","cell":"Vivec, Palace of Vivec","command":"PlaceAtPC rat"}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused outside the allow-list")
    same(#calls, 0, "nothing was sent to the game")
end)

test("screenshot writes a request for the capture helper", function()
    queue('{"id":"f1","action":"screenshot","agent":"worldsmith","cell":"Kingdom Workshop",' ..
          '"position":[4,1,2],"rotation":[0,1.57,0],"filename":"workshop.png"}')
    local report = Bridge.drain()
    same(report.applied, 1, "applied")
    local attempt = table.concat(filesWritten, "\n")
    check(attempt:find("workshop.json", 1, true) ~= nil, "request file named after the shot")
    same(#calls, 0, "a screenshot is not an engine call yet")
end)

--------------------------------------------------------------------------- the queue itself

test("a bad cell is refused and left in the queue, with nothing emitted", function()
    queue('{"id":"g1","action":"spawn_object","cell":"Vivec, Arena","refId":"x","position":[0,0,0]}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    same(#queueLines, 1, "the command stays queued for a human to look at")
    same(#calls, 0, "no engine call")
    check(table.concat(appliedLines, "\n"):find("allow-list", 1, true) ~= nil, "reason recorded")
end)

test("an unknown action never reaches the engine", function()
    queue('{"id":"g2","action":"delete_the_world","cell":"Kingdom Workshop"}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    same(#calls, 0, "nothing happened")
    check(table.concat(appliedLines, "\n"):find("unknown action", 1, true) ~= nil, "reason recorded")
end)

test("malformed JSON is kept, not silently dropped", function()
    queue('{"action":"spawn_object", this is not json}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    same(#queueLines, 1, "kept")
end)

test("applied commands leave the queue, refusals stay", function()
    queue('{"id":"h1","action":"spawn_object","cell":"Kingdom Workshop","refId":"a","position":[0,0,0]}',
          '{"id":"h2","action":"spawn_object","cell":"Nowhere","refId":"b","position":[0,0,0]}',
          '')
    local report = Bridge.drain()
    same(report.applied, 1, "one applied")
    same(report.refused, 1, "one refused")
    same(#queueLines, 1, "only the refusal remains")
    check(queueLines[1]:find('"h2"', 1, true) ~= nil, "and it is the right one")
end)

test("a flood is drained in bounded batches", function()
    Bridge.config.maxPerDrain = 2
    queue('{"id":"i1","action":"spawn_object","cell":"Kingdom Workshop","refId":"a","position":[0,0,0]}',
          '{"id":"i2","action":"spawn_object","cell":"Kingdom Workshop","refId":"b","position":[0,0,0]}',
          '{"id":"i3","action":"spawn_object","cell":"Kingdom Workshop","refId":"c","position":[0,0,0]}')
    local report = Bridge.drain()
    same(report.applied, 2, "two applied")
    same(#queueLines, 1, "one left for the next event")
end)

test("every attempt is attributed to the agent that asked", function()
    queue('{"id":"j1","action":"scale_object","agent":"robby-agent","cell":"Kingdom Workshop",' ..
          '"mpNum":3,"scale":2}')
    Bridge.drain()
    local logged = table.concat(appliedLines, "\n")
    check(logged:find('"agent":"robby-agent"', 1, true) ~= nil, "the agent is on the record")
    check(logged:find('"ok":true', 1, true) ~= nil, "and so is the outcome")
end)

test("weather and time are set for the world, then sent to every player", function()
    queue('{"id":"w1","action":"set_weather","cell":"Kingdom Workshop","weather":3,"next":6,' ..
          '"transition":0.5,"force":true}',
          '{"id":"w2","action":"set_time","cell":"Kingdom Workshop","hour":21.5,"day":3,"timeScale":30}')
    local report = Bridge.drain()
    same(report.applied, 2, "both applied")
    check(joined():find("SetWeatherForceState(true) | SetWeatherCurrent(3) | SetWeatherNext(6) | " ..
          "SetWeatherTransitionFactor(0.5) | SendWorldWeather(0,true,false)", 1, true) ~= nil,
          "weather sequence: " .. joined())
    check(joined():find("SetHour(21.5) | SetDay(3) | SetTimeScale(30) | SendWorldTime(0,true,false)", 1, true) ~= nil,
          "time sequence")
end)

test("set_time with nothing to set is refused", function()
    queue('{"id":"w3","action":"set_time","cell":"Kingdom Workshop"}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    same(#calls, 0, "nothing sent")
end)

test("NPCs can be moved, wounded and killed, and both players see it", function()
    queue('{"id":"n1","action":"move_actor","cell":"Kingdom Workshop","mpNum":9,"position":[1,2,3]}',
          '{"id":"n2","action":"set_actor_health","cell":"Kingdom Workshop","mpNum":9,"health":10}',
          '{"id":"n3","action":"kill_actor","cell":"Kingdom Workshop","mpNum":9}')
    local report = Bridge.drain()
    same(report.applied, 3, "all applied")
    local text = joined()
    check(text:find("SetActorListPid(0) | SendActorPosition(true,false)", 1, true) ~= nil, "sent to pid 0")
    check(text:find("SetActorListPid(1) | SendActorPosition(true,false)", 1, true) ~= nil, "and to pid 1")
    check(text:find("SetActorHealthCurrent(10)", 1, true) ~= nil, "health set")
    check(text:find("SetActorDeathState(1)", 1, true) ~= nil, "dead is the number 1")
    same(text:find("SetActorDeathState(true)"), nil, "never a boolean to the engine")
    check(text:find("SetActorListPid(1) | SendActorDeath(true,false)", 1, true) ~= nil, "death reaches everyone")
end)

test("resurrecting passes the number 0", function()
    queue('{"id":"n4","action":"kill_actor","cell":"Kingdom Workshop","mpNum":9,"resurrect":true}')
    Bridge.drain()
    check(joined():find("SetActorDeathState(0)", 1, true) ~= nil, "alive is 0")
end)

test("an avatar can be moved, re-modelled and restatted", function()
    queue('{"id":"p1","action":"teleport_player","cell":"Kingdom Workshop","pid":1,' ..
          '"position":[10,0,10],"rotation":[0,90]}',
          '{"id":"p2","action":"set_player_model","cell":"Kingdom Workshop","pid":1,' ..
          '"model":"meshes/kos/robot.nif"}',
          '{"id":"p3","action":"set_player_stats","cell":"Kingdom Workshop","pid":1,' ..
          '"health":120,"level":5}')
    local report = Bridge.drain()
    same(report.applied, 3, "all applied")
    local text = joined()
    check(text:find("SetCell(1,Kingdom Workshop) | SetPos(1,10,0,10) | SetRot(1,0,90) | " ..
          "SendCell(1) | SendPos(1)", 1, true) ~= nil, "teleport sequence: " .. text)
    check(text:find("SetModel(1,meshes/kos/robot.nif) | SendBaseInfo(1)", 1, true) ~= nil, "model swap")
    check(text:find("SetHealthCurrent(1,120) | SetLevel(1,5) | SendStatsDynamic(1)", 1, true) ~= nil, "stats")
end)

test("the world can speak to everyone", function()
    queue('{"id":"s1","action":"say","cell":"Kingdom Workshop","message":"the workshop is open"}')
    Bridge.drain()
    check(joined():find("SendMessage(0,the workshop is open,true,false)", 1, true) ~= nil, "said to pid 0")
    check(joined():find("SendMessage(1,the workshop is open,true,false)", 1, true) ~= nil, "and pid 1")
end)

test("the snapshot tells agents who is where", function()
    local state = Bridge.snapshot()
    same(state.players[1].name, "liam", "first player named")
    same(state.players[2].name, "robby", "second player named")
    same(state.players[1].position[1], 0, "liam's x")
    same(state.players[2].position[1], 10, "robby's x")
    same(state.players[1].cell, "Kingdom Workshop", "cell reported")
    local written = fileContents[Bridge.config.statePath]
    check(written ~= nil and #written == 1, "the snapshot was written where agents read it")
    check(written[1]:find('"robby"', 1, true) ~= nil, "and it names the players")
end)

test("an empty queue does nothing at all", function()
    local report = Bridge.drain()
    same(report.applied, 0, "nothing applied")
    same(report.refused, 0, "nothing refused")
    same(#filesWritten, 0, "no file rewritten")
end)

--------------------------------------------------------------------------- feature flags

test("an experiment that is off cannot be reached from the queue", function()
    flagOverrides = { experiments = false, exp_console = true }
    queue('{"id":"k1","action":"console","cell":"Kingdom Workshop","command":"ToggleVanityMode"}')
    local report = Bridge.drain()
    same(report.refused, 1, "refused")
    same(#calls, 0, "nothing reached the engine")
    check(table.concat(appliedLines, "\n"):find("switched off: exp_console", 1, true) ~= nil,
          "the refusal names the flag to switch on")
end)

test("master switch off stops the experiments and leaves the baseline working", function()
    flagOverrides = { experiments = false }
    queue('{"id":"k2","action":"define_record","cell":"Kingdom Workshop","recordId":"x",' ..
          '"model":"meshes/y.nif"}',
          '{"id":"k3","action":"spawn_object","cell":"Kingdom Workshop","refId":"crate","position":[0,0,0]}')
    local report = Bridge.drain()
    same(report.applied, 1, "the baseline command still worked")
    same(report.refused, 1, "the experiment did not")
end)

test("with world edits off nothing is even consumed", function()
    flagOverrides = { world_edits = false }
    queue('{"id":"k4","action":"spawn_object","cell":"Kingdom Workshop","refId":"crate","position":[0,0,0]}')
    local report = Bridge.drain()
    same(report.applied, 0, "nothing applied")
    same(report.world_edits, false, "the report says why")
    same(#queueLines, 1, "the command waits rather than being lost")
end)

test("every applied command records which flags were live", function()
    queue('{"id":"k5","action":"spawn_object","cell":"Kingdom Workshop","refId":"crate","position":[0,0,0]}')
    Bridge.drain()
    local logged = table.concat(appliedLines, "\n")
    check(logged:find('"flags":"', 1, true) ~= nil, "the record carries the flag state")
    check(logged:find("exp_console", 1, true) ~= nil, "naming the live experiments")
end)

--------------------------------------------------------------------------- result

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
