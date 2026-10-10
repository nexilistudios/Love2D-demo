-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Networking for Love2D Platformer Demo
--
-- This module is a thin, game-aware wrapper around the Nexilis LuaJIT binding.
-- It owns the connection, keeps an estimate of the shared world clock, and
-- turns the room chat channel into a small text protocol (every game message
-- starts with "~"; everything else is chat).
--
-- The clock is peer-to-peer: every client broadcasts "T|<tick>" about once a
-- second and each merges forward only (highest tick wins, never backwards).
-- Between heartbeats clients extrapolate with their local clock so the
-- deterministic enemy simulation stays in lock-step for everybody. The server
-- is a pure relay and never touches the clock.

local Config = require("config")
local Json = require("json")

local Net = {}
Net.__index = Net

local function split(s, sep)
    local out = {}
    local start = 1
    while true do
        local i = string.find(s, sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            return out
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
end

local function num(s)
    return tonumber(s) or 0
end

function Net.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Net)
    self.opts = opts
    self.handlers = opts
    self.client = nil
    self.nexilis = nil
    self.connected = false
    self.my_id = 0
    self.my_id_str = "0"
    self.error = nil
    self.sync_tick = nil
    self.sync_time = 0
    self.start_time = love.timer.getTime()
    self.remote = {} -- id string -> true (presence bookkeeping)
    return self
end

function Net:connect()
    local ok, nexilis = pcall(require, "nexilis")
    if not ok then
        self.error = "could not load nexilis binding: " .. tostring(nexilis)
        return false, self.error
    end
    self.nexilis = nexilis

    local this = self
    local client = nexilis.new({
        server_address = Config.SERVER_ADDRESS,
        password = Config.SERVER_PASSWORD,
        authentication_mode = nexilis.AuthenticationMode.SKIP,
        auto_join = true,
        room_timeout_ms = 6000,
        poll_interval_ms = 40,
        on_remote_client_added = function(_, id)
            local s = this:to_id(id)
            this.remote[s] = true
            if this.handlers.on_remote_added then this.handlers.on_remote_added(s) end
        end,
        on_remote_client_removed = function(_, id)
            local s = this:to_id(id)
            this.remote[s] = nil
            if this.handlers.on_remote_removed then this.handlers.on_remote_removed(s) end
        end,
        on_remote_client_position = function(_, id, position)
            if this.handlers.on_remote_position then
                this.handlers.on_remote_position(this:to_id(id), position)
            end
        end,
        on_disconnected = function()
            this.connected = false
            if this.handlers.on_disconnect then this.handlers.on_disconnect() end
        end,
    })

    if not client then
        self.error = "failed to create nexilis client"
        return false, self.error
    end
    self.client = client

    local joined, err = client:connect()
    if not joined then
        self.error = tostring(err or "connection failed")
        pcall(function() client:close() end)
        self.client = nil
        return false, self.error
    end

    self.my_id = client:client_id()
    self.my_id_str = nexilis.id_string(self.my_id)
    self.connected = true
    if self.handlers.on_connect then self.handlers.on_connect() end
    return true
end

function Net:to_id(id)
    if self.nexilis then return self.nexilis.id_string(id) end
    return tostring(id)
end

function Net:is_connected()
    return self.connected and self.client ~= nil and self.client:is_connected()
end

function Net:update()
    if not self.client or not self.connected then return end
    self.client:update()

    local json = self.client:drain_events_json()
    if not json or json == "" or json == "{}" then return end
    local data = Json.decode(json)
    if not data or type(data.chat) ~= "table" then return end
    for _, message in ipairs(data.chat) do
        self:handle_message(message.message, message.sender)
    end
end

function Net:handle_message(message, sender)
    if type(message) ~= "string" or message == "" then return end

    if message:sub(1, 1) == "~" then
        self:handle_protocol(message:sub(2), sender)
        return
    end

    -- World-clock tick. The authoritative sender is chosen by the world; when
    -- no handler is registered we simply trust the message.
    if message:sub(1, 2) == "T|" then
        local tick = tonumber(message:sub(3))
        if tick then
            if self.handlers.on_tick then
                self.handlers.on_tick(sender, tick)
            else
                self.sync_tick = tick
                self.sync_time = love.timer.getTime()
            end
        end
        return
    end

    -- The server also replays join/leave notices and other system lines
    -- through the chat channel (they start with "> "). They are noise here.
    if message:sub(1, 2) == "> " then return end

    if self.handlers.on_chat then self.handlers.on_chat(sender, message) end
end

function Net:handle_protocol(body, sender)
    local parts = split(body, "|")
    local kind = parts[1]
    local event = { type = kind, sender = sender, raw = parts }

    if kind == "S" then
        event.epoch = num(parts[2])
    elseif kind == "J" then
        event.pid = parts[2]
        event.name = parts[3]
        event.char = num(parts[4])
    elseif kind == "B" then
        event.tx, event.ty = num(parts[2]), num(parts[3])
        event.pid = parts[4]
        event.tick = num(parts[5])
    elseif kind == "X" then
        event.tx, event.ty = num(parts[2]), num(parts[3])
        event.pid = parts[4]
    elseif kind == "O" then
        event.tx, event.ty = num(parts[2]), num(parts[3])
        event.pid = parts[4]
    elseif kind == "I" then
        event.tx, event.ty = num(parts[2]), num(parts[3])
        event.pid = parts[4]
    elseif kind == "E" then
        event.index = num(parts[2])
        event.pid = parts[3]
        event.mode = parts[4]
        event.x = parts[5] and num(parts[5]) or nil
        event.tick = parts[6] and num(parts[6]) or nil
        event.vx = parts[7] and num(parts[7]) or nil
    elseif kind == "K" then
        event.index = num(parts[2])
        event.pid = parts[3]
        event.dir = num(parts[4])
        event.x = num(parts[5])
        event.tick = num(parts[6])
    elseif kind == "F" then
        event.pid = parts[2]
        event.x, event.y = num(parts[3]), num(parts[4])
        event.dir = num(parts[5])
        event.tick = num(parts[6])
    elseif kind == "D" then
        event.pid = parts[2]
    elseif kind == "G" then
        event.pid = parts[2]
        event.points = num(parts[3])
    else
        return -- unknown protocol message; ignore
    end

    if self.handlers.on_event then self.handlers.on_event(event) end
end

function Net:send(message)
    if self.client and self.connected then
        pcall(function() self.client:broadcast(message) end)
    end
end

function Net:send_position(x, y, z)
    if self.client and self.connected then
        pcall(function() self.client:send_position(x, y, z) end)
    end
end

-- Estimated shared world tick. Falls back to a local clock until the first
-- peer "T|" tick arrives so the game can run before it is synchronised.
function Net:world_tick()
    local now = love.timer.getTime()
    if self.sync_tick then
        return self.sync_tick + math.floor((now - self.sync_time) * Config.TICKRATE)
    end
    return math.floor((now - self.start_time) * Config.TICKRATE)
end

function Net:close()
    if self.client then
        pcall(function() self.client:close() end)
        self.client = nil
    end
    self.connected = false
end

return Net
