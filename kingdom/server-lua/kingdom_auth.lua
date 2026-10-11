--[[ Kingdom of Science — tailnet login gate for the TES3MP server.

    Who you are is decided by the network, not by typing. The engine hands us the connecting
    player's IP (`GetIP`), the tailnet tells us which account and device that is, and
    `kingdom/auth/kos_auth.py` mints and checks the one password that player keeps.

    Two flows, one entry point:
      * identity has no account  -> mint a password, show it once, ask them to save it
      * identity has an account  -> ask for the password, lock out after repeated misses

    The password never passes through the engine's own account system and is never written to the
    game's files: it is verified by the auth service against a scrypt hash.

    Test it without a game:
      kingdom/tools/lua-5.1/bin/lua kingdom/server-lua/test_kingdom_auth.lua
]]

local Kingdom = {}

local WORLD = (os.getenv and os.getenv("KOS_WORLD_DIR")) or "/home/liamb/kos-world"

Kingdom.config = {
    python = "/usr/bin/python3",
    cli = (os.getenv and os.getenv("KOS_AUTH_CLI"))
        or "/home/liamb/projects/TES3MP/kingdom/auth/kos_auth.py",
    store = (os.getenv and os.getenv("KOS_AUTH_DIR")) or "/home/liamb/kos-auth",
    maxAttempts = 6,
    cacheSeconds = 300,
}

--- This world is private. Access is granted by tailnet user id, checked on every connection, so a
--- device that is shared into the tailnet by anybody else is refused even before a password exists.
--- Liam and Robby only; a third identity cannot enrol no matter what it types.
Kingdom.config.allowedUsers = {
    ["7230364925941255"] = "liam",
    ["6123606715262792"] = "robby",
}

--- The save each player keeps lives on the server under this name, so a personal persistent save
--- follows the *identity* rather than whatever name a client felt like sending.
Kingdom.config.saveNames = {
    ["7230364925941255"] = "liam",
    ["6123606715262792"] = "robby",
}

function Kingdom.allowedRole(userId)
    return Kingdom.config.allowedUsers[tostring(userId)]
end

-- Everything the outside world touches lives here, so tests can replace all of it.
local deps = {
    run = function(command)
        local pipe = io.popen(command, "r")
        if not pipe then return "" end
        local out = pipe:read("*a") or ""
        pipe:close()
        return out
    end,
    send = function(pid, message) SendMessage(pid, message) end,
    getIp = function(pid) return GetIP(pid) end,
    kick = function(pid, reason) Kick(pid, reason) end,
    now = function() return os.time() end,
}

local identityCache = {}   -- ip -> { at = os.time(), identity = {...} }
local pending = {}         -- pid -> { ip, identity, attempts, stage, authorized }
local authorized = {}      -- pid -> { user_id, display }

function Kingdom.setDependencies(replacement)
    for key, value in pairs(replacement) do deps[key] = value end
end

function Kingdom.reset()
    identityCache, pending, authorized = {}, {}, {}
end

function Kingdom.dependencies()
    return deps
end

--------------------------------------------------------------------------- small utilities

local function shellQuote(value)
    local text = tostring(value)
    if text:find("[^%w%._%-/@:]") then
        return "'" .. text:gsub("'", "'\\''") .. "'"
    end
    return text
end

-- The CLI prints one flat JSON object, so decoding stays deliberately small: strings, numbers,
-- booleans. Anything nested is rejected rather than guessed at.
function Kingdom.parseFlatJson(text)
    if type(text) ~= "string" then return nil, "not a string" end
    local body = text:match("%b{}")
    if not body then return nil, "no object found" end
    local result, index, length = {}, 2, #body
    local function skipSpace()
        while index <= length do
            local char = body:sub(index, index)
            if char == " " or char == "\n" or char == "\t" or char == "\r" then index = index + 1
            else break end
        end
    end
    skipSpace()
    if body:sub(index, index) == "}" then return result end
    while index <= length do
        skipSpace()
        if body:sub(index, index) ~= '"' then return nil, "expected a key" end
        index = index + 1
        local key = ""
        while index <= length do
            local char = body:sub(index, index)
            if char == "\\" then
                local escaped = body:sub(index + 1, index + 1)
                if escaped == "n" then key = key .. "\n"
                elseif escaped == "t" then key = key .. "\t"
                else key = key .. escaped end
                index = index + 2
            elseif char == '"' then index = index + 1 break
            else key = key .. char index = index + 1 end
        end
        skipSpace()
        if body:sub(index, index) ~= ":" then return nil, "expected a colon" end
        index = index + 1
        skipSpace()
        local char = body:sub(index, index)
        local value
        if char == '"' then
            index = index + 1
            value = ""
            while index <= length do
                local inner = body:sub(index, index)
                if inner == "\\" then
                    local escaped = body:sub(index + 1, index + 1)
                    if escaped == "n" then value = value .. "\n"
                    elseif escaped == "t" then value = value .. "\t"
                    elseif escaped == "u" then
                        value = value .. "?"   -- not needed by this CLI; refuse to guess
                        index = index + 4
                        inner = ""
                    else value = value .. escaped end
                    index = index + 2
                elseif inner == '"' then index = index + 1 break
                else value = value .. inner index = index + 1 end
            end
        elseif char == "{" or char == "[" then
            return nil, "nested values are not supported"
        else
            local literal = body:match("^([^,}]+)", index)
            if not literal then return nil, "missing value" end
            literal = literal:gsub("%s+$", "")
            index = index + #literal
            if literal == "true" then value = true
            elseif literal == "false" then value = false
            elseif literal == "null" then value = nil
            elseif literal:match("^%-?%d+$") then value = tonumber(literal)
            elseif literal:match("^%-?%d*%.?%d+$") then value = tonumber(literal)
            else return nil, "unsupported literal: " .. literal end
        end
        result[key] = value
        skipSpace()
        local nextChar = body:sub(index, index)
        if nextChar == "," then index = index + 1
        elseif nextChar == "}" then break
        else return nil, "unexpected trailing content" end
    end
    return result
end

local function callCli(args)
    local parts = { shellQuote(Kingdom.config.python), shellQuote(Kingdom.config.cli),
                    "--store", shellQuote(Kingdom.config.store) }
    for _, arg in ipairs(args) do parts[#parts + 1] = shellQuote(arg) end
    local output = deps.run(table.concat(parts, " "))
    local parsed, problem = Kingdom.parseFlatJson(output)
    if not parsed then
        return { status = "error", reason = problem or "unreadable reply", raw = output }
    end
    return parsed
end

function Kingdom.isValidIp(ip)
    return type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

--------------------------------------------------------------------------- identity + auth

function Kingdom.identityFor(ip)
    if not Kingdom.isValidIp(ip) then return nil, "no usable address" end
    local cached = identityCache[ip]
    local now = deps.now()
    if cached and now - cached.at < Kingdom.config.cacheSeconds then
        return cached.identity, nil
    end
    local reply = callCli({ "identify", "--ip", ip })
    if reply.status ~= "ok" then
        return nil, reply.reason or "this address is not on the tailnet"
    end
    identityCache[ip] = { at = now, identity = reply }
    return reply, nil
end

--- Does this identity already keep a password? `verify` answers that without needing one.
function Kingdom.accountState(ip)
    local reply = callCli({ "verify", "--ip", ip, "--secret", "" })
    return reply.status or "error", reply
end

function Kingdom.enroll(ip, display)
    return callCli({ "enroll", "--ip", ip, "--display", display or "" })
end

function Kingdom.verify(ip, secret)
    return callCli({ "verify", "--ip", ip, "--secret", secret })
end

--------------------------------------------------------------------------- the login gate

local function tell(pid, message)
    deps.send(pid, "[Kingdom] " .. message)
end

function Kingdom.onPlayerConnect(pid)
    local ip = deps.getIp(pid)
    local identity, problem = Kingdom.identityFor(ip)
    if not identity then
        pending[pid] = { ip = ip, attempts = 0, stage = "rejected" }
        tell(pid, "Your address is not on the tailnet" .. (problem and (" (" .. problem .. ")") or "") ..
                  " — connect through Tailscale to play here.")
        deps.kick(pid, "not a tailnet address")
        return false
    end

    -- The private-world check comes before anything else, including enrolment: an identity that is
    -- not on the list never gets an account, a prompt, or a look at the world.
    local role = Kingdom.allowedRole(identity.user_id)
    if not role then
        pending[pid] = { ip = ip, identity = identity, attempts = 0, stage = "refused" }
        tell(pid, "This world is private.")
        deps.kick(pid, "not on the guest list")
        return false
    end

    local state, _ = Kingdom.accountState(ip)
    pending[pid] = { ip = ip, identity = identity, attempts = 0, stage = "awaiting", role = role,
                     saveName = Kingdom.config.saveNames[identity.user_id] or role }

    local handle = identity.display_default or identity.user_id
    if state == "enroll" then
        local created = Kingdom.enroll(ip, role)
        if created.status ~= "created" then
            tell(pid, "Could not register you just now — tell Liam to check the auth service.")
            deps.kick(pid, "registration failed")
            return false
        end
        pending[pid].stage = "confirming"
        tell(pid, "Welcome, " .. role .. ". You are new here, so here is your password:")
        tell(pid, created.secret)
        tell(pid, "COPY THAT NOW and keep it somewhere safe — it will never be shown again.")
        tell(pid, "Type:  login <password>   to confirm you saved it.")
        return true
    end

    tell(pid, "Welcome back, " .. role .. ". Type:  login <password>")
    return true
end

function Kingdom.onPlayerSendMessage(pid, message)
    local state = pending[pid]
    if not state then return false end
    if authorized[pid] then return false end

    local typed = tostring(message or ""):match("^%s*(.-)%s*$")
    local secret = typed:match("^[!/]?[Ll][Oo][Gg][Ii][Nn]%s+(.+)$")
    if not secret then
        if typed ~= "" then
            tell(pid, "Only the login command works until you are in. Type:  login <password>")
        end
        return true
    end

    state.attempts = state.attempts + 1
    local reply = Kingdom.verify(state.ip, secret)
    if reply.status == "ok" then
        authorized[pid] = { user_id = reply.user_id, display = reply.display }
        state.stage = "authorized"
        tell(pid, "You are in, " .. (reply.display or "friend") .. ". Welcome to the Kingdom.")
        return true
    end

    if reply.status == "locked" then
        tell(pid, "Too many wrong passwords. Try again in " .. tostring(math.floor(reply.retry_after or 30)) .. " seconds.")
    elseif reply.status == "enroll" then
        tell(pid, "That address has no account yet — reconnect and one will be created.")
    elseif reply.status == "error" then
        tell(pid, "The auth service is not answering (" .. tostring(reply.reason) .. ").")
    else
        tell(pid, "Wrong password. Attempt " .. state.attempts .. " of " .. Kingdom.config.maxAttempts .. ".")
    end

    if state.attempts >= Kingdom.config.maxAttempts then
        deps.kick(pid, "too many failed logins")
        pending[pid] = nil
    end
    return true
end

function Kingdom.onPlayerDisconnect(pid)
    pending[pid] = nil
    authorized[pid] = nil
end

function Kingdom.isAuthorized(pid)
    return authorized[pid] ~= nil
end

function Kingdom.who(pid)
    return authorized[pid]
end

--------------------------------------------------------------------------- engine hooks

function OnPlayerConnect(pid) return Kingdom.onPlayerConnect(pid) end
function OnPlayerSendMessage(pid, message) return Kingdom.onPlayerSendMessage(pid, message) end
function OnPlayerDisconnect(pid) return Kingdom.onPlayerDisconnect(pid) end

return Kingdom
