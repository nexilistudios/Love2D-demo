-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- The world: one Super Mario-style level shared by every player, the local
-- Mario, the remote Marios, the deterministic enemies, and all the rules that
-- connect them. A shared, peer-to-peer world clock drives a fixed 60 Hz
-- simulation, so every client steps the same ticks in the same order.

local Config = require("config")
local Level = require("level")
local Entities = require("entities")
local Player = require("player")
local Sprites = require("sprites")

local World = {}
World.__index = World

local T = Level.T
local TILE = Config.TILE
local DT = Config.FIXED_DT

function World.new(opts)
    opts = opts or {}
    local self = setmetatable({}, World)
    self.net = opts.net
    self.level = Level.build()

    self.emit_fn = function(message)
        if self.net then self.net:send(message) end
    end
    self.entities = Entities.new(self.level, self.emit_fn)

    self.players = {}
    self.by_id = {}
    self.chat = {}
    self.chat_timer = 0
    self.time = 0
    self.cleared = false
    self.send_accum = 0
    self.step_count = 0

    self.camera = { x = 0, y = 0, w = 426, h = 240 }

    self.coin_by_tile = {}
    for _, coin in ipairs(self.level.coins) do
        self.coin_by_tile[coin.tx .. "," .. coin.ty] = coin
    end

    local local_player = Player.new({
        net_id = self.net and self.net.my_id or 0,
        id_str = self.net and self.net.my_id_str or "0",
        name = opts.name or "Mario",
        char = opts.char or 1,
        ["local"] = true,
    })
    local_player:set_spawn(2 * TILE, 13 * TILE - local_player.h)
    local_player.x = local_player.spawn_x
    local_player.y = local_player.spawn_y
    self.local_player = local_player
    self.players[1] = local_player
    self.by_id[local_player.id_str] = local_player
    -- Fireballs are only authoritative for the client that fired them; other
    -- clients hear about the resulting hits through "~E" events. This keeps
    -- fireball kills identical everywhere despite slightly different spawn
    -- timings.
    self.entities.local_pid = local_player.id_str

    self.tick = self.net and self.net:world_tick() or 0
    self.input = { left = false, right = false, jump = false, jump_pressed = false, run = false }
    self.prev_jump = false
    self.chat_active = false

    if self.net then self:bind_net() end
    return self
end

----------------------------------------------------------------------
-- Networking glue
----------------------------------------------------------------------

function World:bind_net()
    local net = self.net
    net.handlers.on_event = function(event) self:handle_event(event) end
    net.handlers.on_chat = function(sender, text) self:handle_chat(sender, text) end
    net.handlers.on_remote_added = function(id_str) self:ensure_remote(id_str) end
    net.handlers.on_remote_removed = function(id_str) self:remove_remote(id_str) end
    net.handlers.on_tick = function(sender, tick) self:on_clock(sender, tick) end
    net.handlers.on_remote_position = function(id_str, position)
        local p = self:ensure_remote(id_str)
        p.last_seen = love.timer.getTime()
        local state = Player.unpack_state(position.z)
        p:set_net_state(position.x, position.y, state)
    end
end

-- The shared world clock converges on the highest tick any client reports and
-- never moves backwards. Every client broadcasts its tick about once a second;
-- a fresh joiner (whose local clock is near zero) is pulled forward to
-- everyone else, and a departing client can never drag the clock back.
function World:on_clock(sender, tick)
    if not tick then return end
    if not self.net.sync_tick or tick > self.net:world_tick() then
        self.net.sync_tick = tick
        self.net.sync_time = love.timer.getTime()
    end
end

----------------------------------------------------------------------
-- Session lifecycle
----------------------------------------------------------------------

-- Rebuild the level and every entity from scratch. Called whenever a new
-- session begins, so a player who joins a server whose previous players have
-- all left gets a fresh Level 1 instead of the kills and broken bricks left
-- behind in the room's broadcast history.
function World:reset_world()
    self.level = Level.build()
    self.coin_by_tile = {}
    for _, coin in ipairs(self.level.coins) do
        self.coin_by_tile[coin.tx .. "," .. coin.ty] = coin
    end
    self.entities = Entities.new(self.level, self.emit_fn)
    self.entities.local_pid = self.local_player.id_str
    self.cleared = false
end

-- A session is identified by a numeric epoch; only a strictly newer epoch
-- resets the world, so replayed history always converges on the newest one.
function World:on_session(epoch)
    if not epoch then return end
    if not self.session_epoch or epoch > self.session_epoch then
        self.session_epoch = epoch
        self:reset_world()
    end
end

-- If nobody else is here shortly after we connect, we are starting a fresh
-- session: mint a new epoch and broadcast it so late joiners rebuild from our
-- point on (and ourselves reset any stale history we replayed).
function World:maybe_start_session()
    if self.session_checked then return end
    self.session_checked = true
    if next(self.net.remote) == nil then
        local epoch = os.time() * 1000 + math.random(0, 999)
        self.session_epoch = epoch
        self:reset_world()
        self.net:send(("~S|%d"):format(epoch))
    end
end

function World:ensure_remote(id_str)
    local p = self.by_id[id_str]
    if p then return p end
    p = Player.new({
        net_id = id_str,
        id_str = id_str,
        name = "Player " .. id_str:sub(-4),
        char = 1,
        ["local"] = false,
        x = 2 * TILE,
        y = 13 * TILE - 16,
    })
    p.target_x, p.target_y = p.x, p.y
    p.last_seen = love.timer.getTime()
    self.by_id[id_str] = p
    self.players[#self.players + 1] = p
    self:add_chat(p.name .. " joined")
    return p
end

function World:remove_remote(id_str)
    local p = self.by_id[id_str]
    if not p then return end
    self.by_id[id_str] = nil
    for i, other in ipairs(self.players) do
        if other == p then table.remove(self.players, i); break end
    end
    self:add_chat(p.name .. " left")
end

function World:prune_remote_players()
    local now = love.timer.getTime()
    -- Refresh anyone the client still reports as present in the room.
    for id_str in pairs(self.net.remote) do
        local p = self.by_id[id_str]
        if p then p.last_seen = now end
    end
    local stale = {}
    for id_str, p in pairs(self.by_id) do
        if not p.is_local and p.last_seen and (now - p.last_seen) > 4 then
            stale[#stale + 1] = id_str
        end
    end
    for _, id_str in ipairs(stale) do self:remove_remote(id_str) end
end

function World:handle_event(event)
    local t = event.type
    if t == "S" then
        self:on_session(event.epoch)
    elseif t == "J" then
        -- Presence (on_remote_client_added) decides who actually exists; the
        -- replayed join history only supplies a name and a character. This
        -- avoids resurrecting players who left long ago.
        if event.pid ~= self.local_player.id_str then
            local p = self.by_id[event.pid]
            if p then
                if event.name and event.name ~= "" then p.name = event.name end
                p.char = math.max(1, math.min(#Config.CHARACTERS, event.char or 1))
            end
        end
    elseif t == "B" then
        self.entities:apply_block_bump(event.tx, event.ty, event.pid, event.tick)
    elseif t == "X" then
        self.entities:break_brick(event.tx, event.ty)
    elseif t == "O" then
        local coin = self.coin_by_tile[event.tx .. "," .. event.ty]
        if coin and not coin.collected then
            coin.collected = true
            local owner = self.by_id[event.pid]
            if owner then self:award(owner, 200, 1) end
        end
    elseif t == "I" then
        self.entities:remove_item(event.tx .. "," .. event.ty, event.pid)
        local owner = self.by_id[event.pid]
        if owner then
            self.entities:score_pop(event.tx * TILE + 8, event.ty * TILE, 1000)
        end
    elseif t == "E" then
        self.entities:enemy_event(event)
    elseif t == "K" then
        self.entities:kick_event(event)
    elseif t == "F" then
        self.entities:fireball_event(event)
    elseif t == "D" then
        local p = self.by_id[event.pid]
        if p and p.is_local == false then p.alive = false end
    elseif t == "G" then
        local p = self.by_id[event.pid]
        if p then p.goal = true end
        self:add_chat((p and p.name or "A player") .. " reached the castle!")
    end
end

function World:handle_chat(sender, text)
    if text:sub(1, 1) == ">" then
        self:add_chat(text)
        return
    end
    local p = self.by_id[sender]
    local name = p and p.name or ("Player " .. tostring(sender):sub(-4))
    self:add_chat(name .. ": " .. text)
end

function World:add_chat(text)
    self.chat[#self.chat + 1] = text
    self.chat_timer = 8
    while #self.chat > 24 do table.remove(self.chat, 1) end
end

----------------------------------------------------------------------
-- Simulation
----------------------------------------------------------------------

function World:read_input()
    local input = self.input
    local left, right, run, jump = false, false, false, false

    if self.chat_active then
        -- Typing must not move Mario.
    elseif self.auto_walk then
        -- Headless integration test driver: run to the right and hop now and
        -- then so blocks and blobs get a workout.
        right, run = true, true
        jump = (self.time % 1.2) < 0.35
        if self.local_player.power == 2 and (self.tick % 90) < 2 then
            self:shoot()
        end
    else
        left = love.keyboard.isDown("left", "a")
        right = love.keyboard.isDown("right", "d")
        run = love.keyboard.isDown("lshift", "rshift")
        jump = love.keyboard.isDown("space", "x", "up", "w")
    end

    -- Latch jump presses until a fixed simulation tick consumes them. The
    -- renderer runs much faster than the 60 Hz simulation, so a press held for
    -- a single frame would otherwise be dropped.
    if jump and not self.prev_jump then input.jump_pressed = true end
    self.prev_jump = jump

    input.left, input.right, input.run, input.jump = left, right, run, jump
end

function World:update(dt)
    self.time = self.time + dt
    self:update_camera_metrics()
    self:read_input()
    if self.net then
        self.net:update()
        self:prune_remote_players()
        -- Give presence a moment to arrive, then decide whether we are the
        -- first player of a fresh session (see maybe_start_session).
        if not self.session_checked and self.time >= 1.5 then
            self:maybe_start_session()
        end
    end

    local target = self.net and self.net:world_tick() or (self.tick + 1)
    if target > self.tick then
        local steps = math.min(target - self.tick, 8)
        for _ = 1, steps do
            self.tick = self.tick + 1
            self:step_tick()
        end
        if target - self.tick > 8 then self.tick = target end
    elseif target < self.tick then
        self.tick = target
    end

    for _, p in ipairs(self.players) do
        if not p.is_local then p:update_remote(dt) end
    end

    self:update_camera(dt)

    self.send_accum = self.send_accum + dt
    if self.net and self.send_accum >= 1 / 30 then
        self.send_accum = 0
        self:send_local_state()
    end

    -- Share our clock about once a second so late joiners and any drifting
    -- client stay in step (forward-only merge on the receiving side).
    if self.net then
        if not self.last_clock_tick or self.tick - self.last_clock_tick >= Config.TICKRATE then
            self.last_clock_tick = self.tick
            self.net:send(("T|%d"):format(self.tick))
        end
    end

    if self.chat_timer > 0 then self.chat_timer = self.chat_timer - dt end
end

function World:step_tick()
    self.step_count = self.step_count + 1
    self.local_player:update_local(DT, self.input, self)
    self.input.jump_pressed = false
    self.entities:step(self.tick, self)
    self:check_goal()
    self.prev_jump = self.input.jump
end

function World:send_local_state()
    local p = self.local_player
    local z = Player.pack_state(p)
    self.net:send_position(p.x, p.y, z)
end

-- Fire Mario throws a fireball. Only the owning client spawns and simulates
-- it; the event tells everyone else to spawn an identical one.
function World:shoot()
    local p = self.local_player
    if p.power ~= 2 or not p.alive or p.goal then return end
    if self.fire_cooldown and self.tick < self.fire_cooldown then return end
    if #self:fireballs_in_flight_for(p.id_str) >= 2 then return end
    self.fire_cooldown = self.tick + 12

    local dir = p.facing or 1
    local x = dir > 0 and (p.x + p.w - 2) or (p.x - 6)
    local y = p.y + 6
    self.entities:spawn_fireball(x, y, dir, p.id_str, self.tick)
    if self.net then
        self.net:send(("~F|%s|%.1f|%.1f|%d|%d"):format(p.id_str, x, y, dir, self.tick))
    end
end

function World:fireballs_in_flight_for(pid)
    local out = {}
    for _, fb in pairs(self.entities.fireballs) do
        if fb.owner == pid then out[#out + 1] = fb end
    end
    return out
end

function World:check_goal()
    local p = self.local_player
    if p.goal or not p.alive then return end
    if p.x + p.w > self.level.flagpoleTx * TILE then
        p.goal = true
        p.vx = 0
        self.cleared = true
        self:award(p, 2000)
        if self.net then self.net:send(("~G|%s|%d"):format(p.id_str, 2000)) end
        self:add_chat("Course clear! Nice work, " .. p.name .. ".")
    end
end

function World:update_camera_metrics()
    local g = love.graphics
    -- Keep the whole world height on screen no matter how the window is sized
    -- (the intended 1280x720 window gives an exact 3x scale). Scaling by the
    -- screen height means the ground is never cropped off the bottom.
    local world_h = self.level.pixelHeight
    local scale = g.getHeight() / world_h
    if scale <= 0 then scale = 1 end
    self.view_scale = scale
    self.camera.w = g.getWidth() / scale
    self.camera.h = world_h
end

function World:update_camera(dt)
    local p = self.local_player
    local target = p.x + p.w / 2 - self.camera.w / 2
    local max_x = math.max(0, self.level.pixelWidth - self.camera.w)
    target = Config.clamp(target, 0, max_x)
    self.camera.x = Config.lerp(self.camera.x, target, math.min(1, dt * 8))
end

----------------------------------------------------------------------
-- Rules
----------------------------------------------------------------------

function World:award(p, points, coins)
    if not p then return end
    p.score = p.score + (points or 0)
    if coins then p.coins = p.coins + coins end
end

function World:collect_coin(p, coin)
    p.coins = p.coins + 1
    p.score = p.score + 200
    if self.net then self.net:send(("~O|%d|%d|%s"):format(coin.tx, coin.ty, p.id_str)) end
end

function World:apply_item(p, item)
    if item.kind == "mushroom" then
        if p.power == 0 then p:set_power(1) else p.score = p.score + 1000 end
    elseif item.kind == "flower" then
        p:set_power(2)
        p.score = p.score + 1000
    elseif item.kind == "star" then
        p.star = 10
        p.score = p.score + 1000
    elseif item.kind == "1up" then
        p.lives = p.lives + 1
    end
end

function World:on_block_bump(p, tx, ty)
    local id = self.level:get(tx, ty)
    local tick = self.tick
    if id == T.BRICK and p.power > 0 then
        if self.entities:break_brick(tx, ty) then
            self:award(p, 50)
            if self.net then self.net:send(("~X|%d|%d|%s"):format(tx, ty, p.id_str)) end
        end
        return
    end
    if self.level:bumpable(tx, ty) then
        local result = self.entities:apply_block_bump(tx, ty, p.id_str, tick)
        if result then
            if result == "coin" then
                p.coins = p.coins + 1
                self:award(p, 200)
            else
                self:award(p, 50)
            end
            if self.net then
                self.net:send(("~B|%d|%d|%s|%d"):format(tx, ty, p.id_str, tick))
            end
        end
    end
end

function World:stomp_enemy(p, foe, tick)
    if foe.kind == "turtle" then
        foe.state = "shell"
        foe.y = foe.base_y
        foe.kick_tick = 0
        if self.net then
            self.net:send(("~E|%d|%s|shell|%.1f|%d"):format(foe.index, p.id_str, foe.x, tick))
        end
    else
        foe.state = "squish"
        foe.dead_tick = tick
        if self.net then
            self.net:send(("~E|%d|%s|squish|%.1f|%d"):format(foe.index, p.id_str, foe.x, tick))
        end
    end
    p.vy = -Config.STOMP_BOUNCE
    self:entities_score(p, 100, foe.x, foe.y)
end

function World:entities_score(p, points, x, y)
    p.score = p.score + points
    self.entities:score_pop(x, y, points)
end

function World:player_hurt(p, foe, tick)
    if p.invuln > 0 or p.star > 0 then return end
    if p.power > 0 then
        p:set_power(p.power == 2 and 1 or 0)
        p.invuln = 1.6
    else
        self:kill_player(p)
    end
end

function World:kill_player(p)
    if not p.alive then return end
    p.alive = false
    p.death_timer = 0
    p.vx = 0
    p.vy = -320
    if p.is_local and self.net then self.net:send("~D|" .. p.id_str) end
end

function World:respawn_player(p)
    p:respawn()
    if p.is_local and self.net then
        self.net:send(("~D|%s"):format(p.id_str))
    end
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

function World:draw()
    local g = love.graphics
    self:update_camera_metrics()

    g.setColor(0.36, 0.56, 0.95)
    g.rectangle("fill", 0, 0, g.getWidth(), g.getHeight())

    g.push()
    g.scale(self.view_scale, self.view_scale)
    g.translate(-math.floor(self.camera.x), -math.floor(self.camera.y))

    self.level:drawBackground(self.camera)
    g.setColor(1, 1, 1)
    self.level:drawTiles(self.camera)
    g.setColor(1, 1, 1)
    self.level:drawCoins(self.camera, self.tick)
    self.entities:draw(self.camera, self.tick)
    g.setColor(1, 1, 1)
    for _, p in ipairs(self.players) do p:draw(self.camera) end
    g.setColor(1, 1, 1)

    g.pop()

    self:draw_hud()
    self:draw_chat()
end

function World:draw_hud()
    local g = love.graphics
    local font = g.getFont()
    g.setColor(1, 1, 1)
    g.print(("COINS %02d    SCORE %06d    LEVEL 1")
        :format(self.local_player.coins, self.local_player.score), 12, 8)

    -- Player scoreboard.
    local y = 30
    for _, p in ipairs(self.players) do
        local tag = (p == self.local_player) and " (you)" or ""
        g.setColor(p.is_local and 1 or 0.85, 1, p.is_local and 1 or 0.85)
        g.print(("%s%s  %06d"):format(p.name, tag, p.score), 12, y)
        y = y + 14
    end

    -- Controls hint bottom-right.
    g.setColor(1, 1, 1, 0.7)
    local hint = "Arrows/WASD move  Space jump  Shift run  T chat"
    g.print(hint, g.getWidth() - font:getWidth(hint) - 12, g.getHeight() - 20)
    g.setColor(1, 1, 1)
end

function World:draw_chat()
    if self.chat_timer <= 0 or #self.chat == 0 then return end
    local g = love.graphics
    local font = g.getFont()
    local y = g.getHeight() - 44
    for i = #self.chat, math.max(1, #self.chat - 7), -1 do
        local line = self.chat[i]
        local alpha = math.min(1, self.chat_timer)
        g.setColor(0, 0, 0, 0.5 * alpha)
        g.rectangle("fill", 8, y - 2, font:getWidth(line) + 8, 16)
        g.setColor(1, 1, 1, alpha)
        g.print(line, 12, y)
        y = y - 16
    end
    g.setColor(1, 1, 1)
end

return World
