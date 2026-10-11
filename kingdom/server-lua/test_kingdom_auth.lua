--[[ Tests for the Kingdom login gate. Run with the Lua 5.1 that TES3MP embeds:

      kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_auth.lua

    The engine and the auth CLI are both replaced with stubs, so this exercises the part that must
    not be wrong: who gets let in, who gets refused before they can even ask, and whether a
    password ever leaks into a shell command or a chat message it should not.
]]

package.path = "./kingdom/server-lua/?.lua;" .. package.path
local Kingdom = dofile("kingdom/server-lua/kingdom_auth.lua")

local LIAM_IP = "100.102.189.126"
local LIAM_USER = "7230364925941255"
local ROBBY_IP = "100.109.247.50"
local ROBBY_USER = "6123606715262792"
local STRANGER_IP = "100.84.99.22"
local STRANGER_USER = "9999999999999999"

local passed, failed = 0, 0
local current = ""

local function check(condition, description)
    if condition then
        passed = passed + 1
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
    Kingdom.reset()
    body()
end

--------------------------------------------------------------------------- stub world

local log, kickLog, commands, replies

local function identityJson(userId, nodeId, login, machine)
    return string.format(
        '{"status":"ok","user_id":"%s","node_id":"%s","login":"%s","machine":"%s","display_default":"%s"}',
        userId, nodeId, login, machine, machine ~= "" and machine or login:match("^[^@]+"))
end

local function defaultRun(command)
    commands[#commands + 1] = command
    local ip = command:match("--ip%s+(%S+)")
    if command:find("identify") then
        if ip == ROBBY_IP then
            return identityJson(ROBBY_USER, "n8Uf25YMwv11CNTRL", "nahxprpht@gmail.com", "")
        elseif ip == LIAM_IP then
            return identityJson(LIAM_USER, "nESEeBiRPP11CNTRL", "liamdev631@gmail.com", "beelink.tail96c9e1.ts.net")
        elseif ip == STRANGER_IP then
            return identityJson(STRANGER_USER, "nSomeoneElse11", "someone@example.com", "someone-pc")
        end
        return '{"status":"error","reason":"peer not found"}'
    end
    local reply = replies[command:find(" verify") and "verify" or "enroll"]
    return reply or '{"status":"error","reason":"no stub"}'
end

local function setup(run)
    log, kickLog, commands = {}, {}, {}
    replies = {}
    Kingdom.setDependencies({
        run = run or defaultRun,
        send = function(pid, message) log[#log + 1] = message end,
        getIp = function(pid) return Kingdom.ips[pid] end,
        kick = function(pid, reason) kickLog[#kickLog + 1] = reason end,
        now = function() return 1000 end,
    })
    Kingdom.ips = { [1] = LIAM_IP, [2] = ROBBY_IP, [3] = STRANGER_IP }
end

local function allMessages()
    return table.concat(log, "\n")
end

--------------------------------------------------------------------------- tests

test("json: reads the flat objects the CLI prints", function()
    local parsed, problem = Kingdom.parseFlatJson('{"status":"ok","user_id":"6123606715262792","retry_after":12.5,"locked":false}')
    check(parsed ~= nil, "should parse: " .. tostring(problem))
    same(parsed.status, "ok", "status")
    same(parsed.user_id, "6123606715262792", "user id stays a string")
    same(parsed.retry_after, 12.5, "floats")
    same(parsed.locked, false, "booleans")

    local decoded = Kingdom.parseFlatJson('{"message":"copy this now \\" and keep it","n":-3}')
    same(decoded.message, 'copy this now " and keep it', "escaped quotes")
    same(decoded.n, -3, "negative numbers")
end)

test("json: refuses what it cannot read rather than guessing", function()
    local parsed, problem = Kingdom.parseFlatJson('{"a":{"b":1}}')
    check(parsed == nil and problem:find("nested") ~= nil, "nested values rejected")
    parsed, problem = Kingdom.parseFlatJson("not json at all")
    check(parsed == nil, "garbage rejected")
end)

test("addresses are validated before they reach a shell", function()
    same(Kingdom.isValidIp(ROBBY_IP), true, "a real address")
    same(Kingdom.isValidIp("100.102.189.126; rm -rf /"), false, "shell metacharacters rejected")
    same(Kingdom.isValidIp(""), false, "empty rejected")
end)

test("a password with a quote cannot break out of the command", function()
    setup()
    replies.verify = '{"status":"denied"}'
    Kingdom.onPlayerConnect(2)
    Kingdom.onPlayerSendMessage(2, "login it's-a\"trap")
    local last = commands[#commands]
    check(last:find("'it'\\''s-a\"trap'", 1, true) ~= nil, "secret is single-quoted: " .. tostring(last))
end)

test("identity lookups are cached", function()
    setup()
    local before = #commands
    Kingdom.identityFor(ROBBY_IP)
    Kingdom.identityFor(ROBBY_IP)
    Kingdom.identityFor(ROBBY_IP)
    same(#commands - before, 1, "one CLI call for three lookups")
end)

test("a stranger is refused before any account can exist", function()
    setup()
    local result = Kingdom.onPlayerConnect(3)
    same(result, false, "connection is rejected")
    same(#kickLog, 1, "kicked once")
    same(kickLog[1], "not on the guest list", "reason")
    check(allMessages():find("private") ~= nil, "told the world is private")
    for _, command in ipairs(commands) do
        check(command:find("enroll") == nil, "no account was ever minted: " .. command)
    end
end)

test("an address that is not on the tailnet is refused", function()
    setup()
    Kingdom.ips[4] = "203.0.113.7"
    same(Kingdom.onPlayerConnect(4), false, "rejected")
    check(kickLog[1]:find("tailnet") ~= nil, "reason mentions the tailnet")
end)

test("Robby's first connection mints a password and asks him to save it", function()
    setup()
    replies.verify = '{"status":"enroll","user_id":"' .. ROBBY_USER .. '"}'
    replies.enroll = '{"status":"created","user_id":"' .. ROBBY_USER ..
                     '","display":"robby","secret":"ABCDE-FGHIJ-KLMNP-QRSTU"}'
    same(Kingdom.onPlayerConnect(2), true, "let in to the login flow")
    check(allMessages():find("ABCDE%-FGHIJ%-KLMNP%-QRSTU") ~= nil, "the password is shown once")
    check(allMessages():find("COPY THAT NOW") ~= nil, "asks them to save it")
    check(allMessages():find("login <password>") ~= nil, "explains how to confirm")
    same(Kingdom.isAuthorized(2), false, "showing a password does not log anybody in")
end)

test("Robby's return connection asks for the password instead", function()
    setup()
    replies.verify = '{"status":"denied","user_id":"' .. ROBBY_USER .. '"}'
    same(Kingdom.onPlayerConnect(2), true, "let in to the login flow")
    check(allMessages():find("Welcome back, robby") ~= nil, "greets him by role")
    check(allMessages():find("COPY THAT NOW") == nil, "no password is re-revealed")
end)

test("the right password logs him in, under his identity", function()
    setup()
    replies.verify = '{"status":"denied"}'
    Kingdom.onPlayerConnect(2)
    replies.verify = '{"status":"ok","user_id":"' .. ROBBY_USER .. '","display":"robby"}'
    same(Kingdom.onPlayerSendMessage(2, "login ABCDE-FGHIJ-KLMNP-QRSTU"), true, "message consumed")
    same(Kingdom.isAuthorized(2), true, "authorized")
    same(Kingdom.who(2).user_id, ROBBY_USER, "logged in as the tailnet identity")
end)

test("chat is swallowed until logged in, and left alone after", function()
    setup()
    replies.verify = '{"status":"denied"}'
    Kingdom.onPlayerConnect(2)
    same(Kingdom.onPlayerSendMessage(2, "hello world"), true, "blocked before login")
    check(allMessages():find("Only the login command works") ~= nil, "explains why")

    replies.verify = '{"status":"ok","user_id":"' .. ROBBY_USER .. '","display":"robby"}'
    Kingdom.onPlayerSendMessage(2, "login ABCDE-FGHIJ-KLMNP-QRSTU")
    same(Kingdom.onPlayerSendMessage(2, "hello world"), false, "chat flows normally once logged in")
end)

test("wrong passwords lock and then kick", function()
    setup()
    replies.verify = '{"status":"denied"}'
    Kingdom.onPlayerConnect(2)
    for attempt = 1, Kingdom.config.maxAttempts - 1 do
        Kingdom.onPlayerSendMessage(2, "login WRONG-WRONG-WRONG-WRONG")
    end
    check(allMessages():find("Attempt 5 of 6") ~= nil, "counts attempts back to the player")

    replies.verify = '{"status":"locked","retry_after":60}'
    same(Kingdom.onPlayerSendMessage(2, "login WRONG-WRONG-WRONG-WRONG"), true, "still gated")
    check(allMessages():find("Try again in 60 seconds") ~= nil, "reports the lockout window")

    replies.verify = '{"status":"denied"}'
    Kingdom.onPlayerSendMessage(2, "login WRONG-WRONG-WRONG-WRONG")
    same(#kickLog, 1, "kicked after the final attempt")
    same(kickLog[1], "too many failed logins", "reason")
    same(Kingdom.isAuthorized(2), false, "never authorized")
end)

test("Liam's own node is on the guest list too", function()
    setup()
    replies.verify = '{"status":"denied"}'
    same(Kingdom.onPlayerConnect(1), true, "let in")
    check(allMessages():find("Welcome back, liam") ~= nil, "recognised as liam, not by IP")
    same(#kickLog, 0, "not kicked")
end)

test("a dead auth service does not fail open", function()
    setup()
    replies.verify = '{"status":"error","reason":"tailscale lookup failed"}'
    Kingdom.onPlayerConnect(2)
    replies.verify = '{"status":"error","reason":"tailscale lookup failed"}'
    Kingdom.onPlayerSendMessage(2, "login whatever-I-say-it-is")
    same(Kingdom.isAuthorized(2), false, "an error is never a login")
    check(allMessages():find("not answering") ~= nil, "says the service is down")
end)

--------------------------------------------------------------------------- result

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
