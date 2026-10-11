--[[ Tests for the feature flags. Run:

      kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_flags.lua

    What matters here is that the default answer is no, and that a mistake in the flags file cannot
    turn on something that does not exist.
]]

package.path = "./kingdom/server-lua/?.lua;" .. package.path
local json = require("kingdom_json")
local Flags = dofile("kingdom/server-lua/kingdom_flags.lua")

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

local fileBody

local function withFlags(table_)
    fileBody = table_ and json.encode(table_) or nil
    Flags.setDependencies({
        read = function() return fileBody end,
        log = function() end,
    })
end

local function test(name, body)
    current = name
    fileBody = nil
    Flags.setDependencies({ read = function() return fileBody end, log = function() end })
    body()
end

test("a flag nobody has heard of is off", function()
    withFlags({ made_up_flag = true, experiments = true })
    same(Flags.enabled("made_up_flag"), false, "unknown names cannot enable anything")
    same(Flags.isKnown("made_up_flag"), false, "and are not known")
end)

test("an empty or missing file means everything baseline is off too", function()
    withFlags(nil)
    same(Flags.enabled("world_edits"), false, "no file, no permissions")
    same(Flags.enabled("experiments"), false, "master switch off")
end)

test("a listed flag is on only when the file says so", function()
    withFlags({ world_edits = true, weather_control = false })
    same(Flags.enabled("world_edits"), true, "explicitly on")
    same(Flags.enabled("weather_control"), false, "explicitly off")
    same(Flags.enabled("avatar_control"), false, "absent means off")
end)

test("the master switch holds the experiments down", function()
    withFlags({ experiments = false, exp_custom_models = true, exp_console = true })
    same(Flags.enabled("exp_custom_models"), false, "an experiment cannot be on while the switch is off")
    same(Flags.enabled("exp_console"), false, "nor another one")

    withFlags({ experiments = true, exp_custom_models = true })
    same(Flags.enabled("exp_custom_models"), true, "switch on and flag named: live")
    same(Flags.enabled("exp_console"), false, "but only the flag that was named")
end)

test("the master switch does not gate the baseline features", function()
    withFlags({ experiments = false, world_edits = true, screenshots = true })
    same(Flags.enabled("world_edits"), true, "baseline work with experiments off")
    same(Flags.enabled("screenshots"), true, "and so does the rest of the baseline")
end)

test("a malformed file leaves everything off rather than guessing", function()
    fileBody = "{ this is not json"
    Flags.setDependencies({ read = function() return fileBody end, log = function() end })
    same(Flags.enabled("world_edits"), false, "unreadable means off")
    same(Flags.enabled("experiments"), false, "including the master switch")
end)

test("flipping the file takes effect on the next look", function()
    withFlags({ world_edits = true })
    same(Flags.enabled("screenshots"), false, "starts off")
    same(Flags.raw().screenshots, nil, "not in the file")

    -- the file changes underneath us, as it does when someone runs the flags CLI
    fileBody = json.encode({ world_edits = true, screenshots = true })
    same(Flags.enabled("screenshots"), false, "cached until reloaded")
    Flags.reload()
    same(Flags.enabled("screenshots"), true, "and on straight after")
end)

test("all() reports every known flag, and liveSummary names the live ones", function()
    withFlags({ experiments = true, exp_console = true, world_edits = true,
                weather_control = true, screenshots = true, world_speech = true,
                avatar_control = true, exp_custom_models = true, exp_npc_control = true,
                exp_player_remodel = true })
    local all = Flags.all()
    same(all.world_edits, true, "world_edits reported")
    same(all.exp_hot_reload, false, "a flag left off is reported off")
    same(all.experiments, true, "the master switch is reported like any other")

    local summary = Flags.liveSummary()
    check(summary:find("exp_console", 1, true) ~= nil, "summary names a live experiment")
    check(summary:find("exp_hot_reload", 1, true) == nil, "and omits the ones that are off")

    withFlags({})
    same(Flags.liveSummary(), "none", "nothing live reads as none")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
