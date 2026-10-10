-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Tiny JSON decoder for the strings produced by the Nexilis Lua binding
-- (drain_events_json). Only decoding is implemented, which is all the game
-- needs. It handles objects, arrays, strings, numbers, booleans and null.

local Json = {}

local escapes = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", ["b"] = "\b",
    ["f"] = "\f", ["n"] = "\n", ["r"] = "\r", ["t"] = "\t",
}

local function parse_string(s, i)
    -- s[i] is the opening quote.
    local out = {}
    i = i + 1
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string") end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == "u" then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16) or 63
                -- Encode as UTF-8 (BMP only; good enough for our ASCII data).
                if code < 0x80 then
                    out[#out + 1] = string.char(code)
                elseif code < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(code / 64),
                        0x80 + code % 64)
                else
                    out[#out + 1] = string.char(0xE0 + math.floor(code / 4096),
                        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
                end
                i = i + 6
            else
                out[#out + 1] = escapes[e] or e
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function skip_ws(s, i)
    while true do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else return i end
    end
end

local parse_value

local function parse_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local value
        value, i = parse_value(s, i)
        arr[#arr + 1] = value
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "," then i = i + 1 else return arr, i + 1 end
    end
end

local function parse_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        i = skip_ws(s, i)
        local key
        key, i = parse_string(s, i)
        i = skip_ws(s, i)
        i = i + 1 -- ':'
        local value
        value, i = parse_value(s, i)
        obj[key] = value
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "," then i = i + 1 else return obj, i + 1 end
    end
end

parse_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return parse_string(s, i) end
    if c == "{" then return parse_object(s, i) end
    if c == "[" then return parse_array(s, i) end
    if c == "t" then return true, i + 4 end
    if c == "f" then return false, i + 5 end
    if c == "n" then return nil, i + 4 end
    -- number
    local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    return tonumber(num), i + #num
end

function Json.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, value = pcall(function() return (parse_value(s, 1)) end)
    if not ok then return nil end
    return value
end

return Json
