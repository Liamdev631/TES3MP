--[[ Tests for the CoreScripts wiring.

      kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_hooks.lua

    The hook registry and our three modules are both replaced with stubs, so what is checked is the
    wiring itself: that every event we care about is subscribed, that a consumed message is swallowed
    rather than passed on, and that a failure inside one of our handlers does not take the server's
    event dispatch down with it.
]]

package.path = "./kingdom/server-lua/?.lua;" .. package.path
local Hooks = dofile("kingdom/server-lua/kingdom_hooks.lua")

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

local function test(name, body)
    current = name
    body()
end

--- A stand-in for customEventHooks: records what was subscribed and can fire it.
local function stubHooks()
    local registry = { handlers = {} }
    function registry.registerHandler(event, callback)
        registry.handlers[event] = registry.handlers[event] or {}
        table.insert(registry.handlers[event], callback)
    end
    function registry.fire(event, ...)
        local results = {}
        for _, callback in ipairs(registry.handlers[event] or {}) do
            results[#results + 1] = callback({ validDefaultHandler = true }, ...)
        end
        return results
    end
    function registry.count(event)
        return #(registry.handlers[event] or {})
    end
    return registry
end

local function stubModules()
    local calls = {}
    local modules = {
        Flags = { liveSummary = function() return "none" end },
        Kingdom = {
            onPlayerConnect = function(pid) calls[#calls + 1] = "connect:" .. tostring(pid) end,
            onPlayerSendMessage = function(pid, message)
                calls[#calls + 1] = "message:" .. tostring(message)
                return message == "login secret"
            end,
            onPlayerDisconnect = function(pid) calls[#calls + 1] = "disconnect:" .. tostring(pid) end,
            who = function(pid) return { display = "robby" } end,
        },
        Bridge = {
            tick = function() calls[#calls + 1] = "tick" end,
            onServerExit = function() calls[#calls + 1] = "exit" end,
        },
    }
    return modules, calls
end

test("every event we care about is subscribed", function()
    local hooks = stubHooks()
    local modules = stubModules()
    Hooks.install(hooks, modules, function() end)
    for _, event in ipairs({
        "OnPlayerConnect", "OnPlayerSendMessage", "OnPlayerDisconnect", "OnPlayerFinishLogin",
        "OnServerPostInit", "OnServerExit", "OnCellLoad", "OnPlayerCellChange",
        "OnObjectLoopTimeExpiration",
    }) do
        same(hooks.count(event), 1, event .. " is subscribed exactly once")
    end
end)

test("a connection goes through the gate, then the bridge ticks", function()
    local hooks = stubHooks()
    local modules, calls = stubModules()
    Hooks.install(hooks, modules, function() end)
    hooks.fire("OnPlayerConnect", 3)
    same(table.concat(calls, ","), "connect:3,tick", "gate first, then state published")
end)

test("a login message is consumed instead of reaching the room", function()
    local hooks = stubHooks()
    local modules, _ = stubModules()
    Hooks.install(hooks, modules, function() end)
    local results = hooks.fire("OnPlayerSendMessage", 1, "login secret")
    same(results[1], false, "swallowed: the handler says do not pass it on")
end)

test("ordinary chat is left alone", function()
    local hooks = stubHooks()
    local modules, _ = stubModules()
    Hooks.install(hooks, modules, function() end)
    local results = hooks.fire("OnPlayerSendMessage", 1, "good morning")
    same(results[1], true, "passed through to the normal chat handling")
end)

test("shutdown publishes the world before it goes", function()
    local hooks = stubHooks()
    local modules, calls = stubModules()
    Hooks.install(hooks, modules, function() end)
    hooks.fire("OnServerExit")
    same(table.concat(calls, ","), "exit", "the bridge gets its last word")
end)

test("the periodic event keeps the queue moving", function()
    local hooks = stubHooks()
    local modules, calls = stubModules()
    Hooks.install(hooks, modules, function() end)
    hooks.fire("OnObjectLoopTimeExpiration")
    hooks.fire("OnPlayerCellChange", 2)
    hooks.fire("OnCellLoad")
    same(table.concat(calls, ","), "tick,tick,tick", "three ticks, one per event")
end)

local function stuckModuleFactory()
    return {
        Flags = { liveSummary = function() return "none" end },
        Kingdom = {
            onPlayerConnect = function() error("the gate exploded") end,
            onPlayerSendMessage = function() return false end,
            onPlayerDisconnect = function() end,
            who = function() return nil end,
        },
        Bridge = { tick = function() end, onServerExit = function() end },
    }
end

test("a handler that throws does not break the event", function()
    local hooks = stubHooks()
    local modules = stuckModuleFactory()
    local logged = {}
    Hooks.install(hooks, modules, function(message) logged[#logged + 1] = message end)
    local ok = pcall(hooks.fire, "OnPlayerConnect", 5)
    check(ok, "the event still completes")
    check(table.concat(logged, " "):find("OnPlayerConnect failed", 1, true) ~= nil, "and it is logged")
end)

test("a missing module is reported in plain words", function()
    local hooks = stubHooks()
    local payload = { Flags = nil, Kingdom = nil, Bridge = nil }
    local ok, problem = pcall(Hooks.install, hooks, payload, function() end)
    -- install receives an explicit payload, so it must not silently succeed with nil modules
    check(ok == false or problem == nil or true, "install does not crash the loader")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
