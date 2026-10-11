--[[ A small JSON reader/writer for the Kingdom's server scripts.

    Deliberately not a general JSON library: it handles what our own tooling emits — flat objects of
    scalars, plus one level of arrays — and refuses anything else instead of guessing. No dependencies,
    because the engine's Lua has none to offer.
]]

local json = {}

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decodeString(text, index)
    local out = {}
    index = index + 1
    while index <= #text do
        local char = text:sub(index, index)
        if char == "\\" then
            local code = text:sub(index + 1, index + 1)
            if code == "u" then
                local hex = text:sub(index + 2, index + 5)
                local codepoint = tonumber(hex, 16)
                if not codepoint then return nil, "bad unicode escape" end
                -- Only the range that matters for paths and names; anything above is refused.
                if codepoint > 127 then return nil, "non-ascii escapes are not supported" end
                out[#out + 1] = string.char(codepoint)
                index = index + 6
            else
                local mapped = escapes[code]
                if not mapped then return nil, "bad escape \\" .. code end
                out[#out + 1] = mapped
                index = index + 2
            end
        elseif char == '"' then
            return table.concat(out), index + 1
        else
            out[#out + 1] = char
            index = index + 1
        end
    end
    return nil, "unterminated string"
end

local function decodeValue(text, index)
    local char = text:sub(index, index)
    if char == '"' then return decodeString(text, index) end
    if char == "[" then
        local values, value = {}, nil
        index = index + 1
        while true do
            while text:sub(index, index):match("%s") do index = index + 1 end
            if text:sub(index, index) == "]" then return values, index + 1 end
            value, index = decodeValue(text, index)
            if value == nil then return nil, index end
            values[#values + 1] = value
            while text:sub(index, index):match("%s") do index = index + 1 end
            local sep = text:sub(index, index)
            if sep == "," then index = index + 1
            elseif sep == "]" then return values, index + 1
            else return nil, "expected , or ] in array" end
        end
    end
    local literal = text:match("^([^,}%]%s]+)", index)
    if not literal then return nil, "missing value" end
    if literal == "true" then return true, index + #literal end
    if literal == "false" then return false, index + #literal end
    if literal == "null" then return json.null, index + #literal end
    local number = tonumber(literal)
    if number then return number, index + #literal end
    return nil, "unsupported literal: " .. literal
end

--- Decode one JSON object. Returns (table) or (nil, reason).
function json.decode(text)
    if type(text) ~= "string" then return nil, "not a string" end
    local start = text:find("{", 1, true)
    if not start then return nil, "no object found" end
    local result, index = {}, start + 1
    while true do
        while text:sub(index, index):match("%s") do index = index + 1 end
        local char = text:sub(index, index)
        if char == "}" then return result end
        if char ~= '"' then return nil, "expected a key" end
        local key
        key, index = decodeString(text, index)
        if key == nil then return nil, index end
        while text:sub(index, index):match("%s") do index = index + 1 end
        if text:sub(index, index) ~= ":" then return nil, "expected a colon" end
        index = index + 1
        while text:sub(index, index):match("%s") do index = index + 1 end
        local value, message = decodeValue(text, index)
        if value == nil and message ~= nil then return nil, message end
        index = message
        if value == json.null then value = nil end
        result[key] = value
        while text:sub(index, index):match("%s") do index = index + 1 end
        local sep = text:sub(index, index)
        if sep == "," then index = index + 1
        elseif sep == "}" then return result
        else return nil, "unexpected trailing content" end
    end
end

local function encodeString(value)
    local out = value:gsub('[%c"\\]', function(char)
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        if char == "\n" then return "\\n" end
        if char == "\t" then return "\\t" end
        if char == "\r" then return "\\r" end
        return string.format("\\u%04x", string.byte(char))
    end)
    return '"' .. out .. '"'
end

local function encodeValue(value)
    local kind = type(value)
    if kind == "string" then return encodeString(value) end
    if kind == "number" then
        if value == math.floor(value) and math.abs(value) < 1e15 then
            return string.format("%d", value)
        end
        return string.format("%.6g", value)
    end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "table" then
        local isArray = #value > 0
        local parts = {}
        if isArray then
            for _, item in ipairs(value) do parts[#parts + 1] = encodeValue(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for key, item in pairs(value) do
            if item ~= nil then
                parts[#parts + 1] = encodeString(tostring(key)) .. ":" .. encodeValue(item)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

--- Encode a value. Keys are sorted, so the same table always prints the same way (which is what
--- makes the audit logs comparable).
function json.encode(value)
    if type(value) == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        local parts = {}
        for _, key in ipairs(keys) do
            if value[key] ~= nil then
                parts[#parts + 1] = encodeString(key) .. ":" .. encodeValue(value[key])
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return encodeValue(value)
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

return json
