-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Players: the local Mario (full physics + input) and remote Marios (smooth
-- interpolation of the positions the server relays). Small and big (and fire)
-- share the same code; only the hitbox and the sprite set change.

local Config = require("config")
local Sprites = require("sprites")

local Player = {}
Player.__index = Player

local TILE = Config.TILE
Player.WIDTH = 12

local function height_for(power)
    return power == 0 and 16 or 30
end

-- Pack the small amount of state the server position packet can carry into a
-- float < 2048 so every client can render remote players faithfully.
local ACTIONS = { idle = 0, walk = 1, jump = 2, skid = 3, dead = 4, climb = 5, crouch = 6 }

function Player.pack_state(p)
    local z = 0
    local function push(value, bits)
        z = z + value * (2 ^ bits)
    end
    local char = (p.char - 1) % 8
    local action = ACTIONS[p.action or "idle"] or 0
    z = char
    z = z + p.power * 8
    z = z + (p.facing < 0 and 1 or 0) * 8 * 4
    z = z + action * 8 * 4 * 2
    z = z + (p.alive and 1 or 0) * 8 * 4 * 2 * 8
    z = z + (p.star > 0 and 1 or 0) * 8 * 4 * 2 * 8 * 2
    return z
end

function Player.unpack_state(z)
    z = math.floor((z or 0) + 0.5)
    if z < 0 then z = 0 end
    local char = (z % 8) + 1; z = math.floor(z / 8)
    local power = z % 4; z = math.floor(z / 4)
    local facing = z % 2; z = math.floor(z / 2)
    local action = z % 8; z = math.floor(z / 8)
    local alive = z % 2; z = math.floor(z / 2)
    local star = z % 2
    local action_name = "idle"
    for name, value in pairs(ACTIONS) do
        if value == action then action_name = name end
    end
    return {
        char = char,
        power = power,
        facing = facing == 0 and 1 or -1,
        action = action_name,
        alive = alive == 1,
        star = star == 1,
    }
end

function Player.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Player)
    self.net_id = opts.net_id
    self.id_str = opts.id_str or "0"
    self.name = opts.name or "Player"
    self.char = opts.char or 1
    self.is_local = opts["local"] ~= false

    self.power = 0
    self.w = Player.WIDTH
    self.h = height_for(0)
    self.x = opts.x or 2 * TILE
    self.y = opts.y or (13 * TILE - self.h)
    self.vx = 0
    self.vy = 0
    self.on_ground = false
    self.facing = 1
    self.alive = true
    self.star = 0
    self.invuln = 0
    self.death_timer = 0
    self.action = "idle"
    self.anim_time = 0
    self.score = 0
    self.coins = 0
    self.lives = 3
    self.goal = false

    -- remote interpolation
    self.target_x = self.x
    self.target_y = self.y
    self.net_vx = 0
    self.net_vy = 0

    self.spawn_x = self.x
    self.spawn_y = self.y
    return self
end

function Player:set_spawn(x, y)
    self.spawn_x = x
    self.spawn_y = y
end

function Player:respawn()
    self.power = 0
    self.w = Player.WIDTH
    self.h = height_for(0)
    self.x = self.spawn_x
    self.y = self.spawn_y
    self.vx, self.vy = 0, 0
    self.alive = true
    self.death_timer = 0
    self.invuln = 1.5
    self.star = 0
    self.goal = false
    self.on_ground = false
    if self.is_local then
        self.target_x, self.target_y = self.x, self.y
    end
end

function Player:set_power(power)
    local feet = self.y + self.h
    self.power = power
    self.h = height_for(power)
    self.y = feet - self.h
end

function Player:rect()
    return self.x, self.y, self.w, self.h
end

function Player:center()
    return self.x + self.w / 2, self.y + self.h / 2
end

----------------------------------------------------------------------
-- Local physics
----------------------------------------------------------------------

local function solid_at(level, x, y, w, h)
    local x1 = math.floor(x / TILE)
    local x2 = math.floor((x + w - 1) / TILE)
    local y1 = math.floor(y / TILE)
    local y2 = math.floor((y + h - 1) / TILE)
    for ty = y1, y2 do
        for tx = x1, x2 do
            if level:solid(tx, ty) then return true end
        end
    end
    return false
end

local function move_x(level, p, dx)
    if dx == 0 then return end
    p.x = p.x + dx
    local y1 = math.floor(p.y / TILE)
    local y2 = math.floor((p.y + p.h - 1) / TILE)
    if dx > 0 then
        local tx = math.floor((p.x + p.w - 1) / TILE)
        for ty = y1, y2 do
            if level:solid(tx, ty) then
                p.x = tx * TILE - p.w
                p.vx = 0
                break
            end
        end
    else
        local tx = math.floor(p.x / TILE)
        for ty = y1, y2 do
            if level:solid(tx, ty) then
                p.x = (tx + 1) * TILE
                p.vx = 0
                break
            end
        end
    end
end

-- Returns true and the bumped tile coordinates if the head hit a block.
local function move_y(level, p, dy)
    if dy == 0 then return end
    local hit = nil
    p.y = p.y + dy
    local x1 = math.floor(p.x / TILE)
    local x2 = math.floor((p.x + p.w - 1) / TILE)
    if dy > 0 then
        local ty = math.floor((p.y + p.h - 1) / TILE)
        for tx = x1, x2 do
            if level:solid(tx, ty) then
                p.y = ty * TILE - p.h
                p.vy = 0
                p.on_ground = true
                break
            end
        end
    else
        local ty = math.floor(p.y / TILE)
        for tx = x1, x2 do
            if level:solid(tx, ty) then
                p.y = (ty + 1) * TILE
                p.vy = 0
                -- Prefer the block closest to the player centre.
                local cx = p.x + p.w / 2
                if not hit or math.abs((tx + 0.5) * TILE - cx) < math.abs((hit.x + 0.5) * TILE - cx) then
                    hit = { x = tx, y = ty }
                end
            end
        end
    end
    return hit
end

function Player:update_local(dt, input, world)
    if not self.alive then
        self.death_timer = self.death_timer + dt
        self.vy = self.vy + Config.GRAVITY * dt
        self.y = self.y + self.vy * dt
        self.action = "dead"
        if self.death_timer > 2.4 then world:respawn_player(self) end
        return
    end
    if self.goal then
        self.action = "walk"
        self.anim_time = self.anim_time + dt
        return
    end

    local level = world.level
    local run = input.run
    local max_speed = run and Config.MAX_RUN_SPEED or Config.MAX_WALK_SPEED
    local accel = run and Config.RUN_ACCEL or Config.WALK_ACCEL

    local moving = false
    if input.left and not input.right then
        self.vx = self.vx - accel * dt
        self.facing = -1
        moving = true
    elseif input.right and not input.left then
        self.vx = self.vx + accel * dt
        self.facing = 1
        moving = true
    end

    if not moving then
        local friction = Config.FRICTION * dt
        if math.abs(self.vx) <= friction then
            self.vx = 0
        else
            self.vx = self.vx - Config.sign(self.vx) * friction
        end
    end

    if self.vx > max_speed then self.vx = max_speed end
    if self.vx < -max_speed then self.vx = -max_speed end

    if input.jump_pressed and self.on_ground then
        self.vy = -Config.JUMP_VELOCITY
        self.on_ground = false
    end

    local gravity = Config.GRAVITY
    if self.vy < 0 and input.jump then gravity = gravity * Config.JUMP_HOLD_GRAVITY end
    self.vy = self.vy + gravity * dt
    if self.vy > Config.MAX_FALL_SPEED then self.vy = Config.MAX_FALL_SPEED end

    self.on_ground = false
    move_x(level, self, self.vx * dt)
    local hit = move_y(level, self, self.vy * dt)
    if hit then world:on_block_bump(self, hit.x, hit.y) end

    -- Ground probe: standing exactly on a surface leaves the AABB a pixel
    -- above the tile below, so a downward-collision test alone would flicker
    -- "on ground" from tick to tick and make jumping unreliable.
    if not self.on_ground and self.vy >= 0 then
        local ty = math.floor((self.y + self.h) / TILE)
        local tx1 = math.floor(self.x / TILE)
        local tx2 = math.floor((self.x + self.w - 1) / TILE)
        for tx = tx1, tx2 do
            if level:solid(tx, ty) then
                self.on_ground = true
                break
            end
        end
    end

    -- World bounds.
    if self.x < 0 then self.x = 0; self.vx = 0 end
    local max_x = level.pixelWidth - self.w
    if self.x > max_x then self.x = max_x; self.vx = 0 end

    -- Animation state.
    if not self.on_ground then
        self.action = "jump"
    elseif self.vx ~= 0 and ((input.left and self.vx > 6) or (input.right and self.vx < -6)) then
        self.action = "skid"
    elseif math.abs(self.vx) > 4 then
        self.action = "walk"
        self.anim_time = self.anim_time + dt * (2 + math.abs(self.vx) / 18)
    else
        self.action = "idle"
    end

    if self.star > 0 then
        self.star = self.star - dt
        if self.star < 0 then self.star = 0 end
    end
    if self.invuln > 0 then
        self.invuln = self.invuln - dt
        if self.invuln < 0 then self.invuln = 0 end
    end

    -- Fell into a pit.
    if self.y > level.pixelHeight + 24 then
        world:kill_player(self)
    end
end

----------------------------------------------------------------------
-- Remote interpolation
----------------------------------------------------------------------

function Player:set_net_state(x, y, state)
    self.net_action = state.action
    self.net_facing = state.facing
    self.net_power = state.power
    self.net_alive = state.alive
    self.net_star = state.star and 1 or 0
    self.facing = state.facing or 1
    if state.power and state.power ~= self.power then
        self:set_power(state.power)
    end
    self.alive = state.alive
    self.target_x = x
    self.target_y = y
end

function Player:update_remote(dt)
    local nx = Config.lerp(self.x, self.target_x, math.min(1, dt * 16))
    local ny = Config.lerp(self.y, self.target_y, math.min(1, dt * 16))
    self.net_vx = (nx - self.x) / math.max(dt, 0.0001)
    self.net_vy = (ny - self.y) / math.max(dt, 0.0001)
    self.x, self.y = nx, ny
    self.action = self.net_action or "idle"
    if self.net_star and self.net_star > 0 then
        self.anim_time = self.anim_time + dt * 4
    elseif self.action == "walk" then
        self.anim_time = self.anim_time + dt * (2 + math.abs(self.net_vx) / 18)
    end
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local function walk_frame(t)
    local frames = { "walk1", "walk2", "walk3", "walk2" }
    return frames[(math.floor(t) % #frames) + 1]
end

-- HSV to RGB, used for the cycling star tint. Kept local so the star works on
-- every LÖVE 11.x (love.math has colorFromHSV but no colorFromHSL).
local function hsv(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p end
    if i == 1 then return q, v, p end
    if i == 2 then return p, v, t end
    if i == 3 then return p, q, v end
    if i == 4 then return t, p, v end
    return v, p, q
end

function Player:current_frame()
    if not self.alive then return "dead" end
    if self.action == "jump" then return "jump" end
    if self.action == "skid" then return "skid" end
    if self.action == "walk" then return walk_frame(self.anim_time) end
    return "idle"
end

function Player:draw(camera)
    if self.invuln and self.invuln > 0 and math.floor(love.timer.getTime() * 16) % 2 == 0 then
        return
    end
    local size = self.power == 0 and "small" or "big"
    local frame = self:current_frame()
    local img = Sprites.player(self.char, size, frame, self.power == 2)
    if not img then return end
    local sw, sh = img:getWidth(), img:getHeight()
    local sx = self.x - (sw - self.w) / 2
    local sy = self.y + self.h - sh

    if (self.star and self.star > 0) or (self.net_star and self.net_star > 0) then
        local hue = (love.timer.getTime() * 6) % 1
        local r, g, b = hsv(hue, 0.9, 0.95)
        love.graphics.setColor(r, g, b)
    end

    if self.facing and self.facing < 0 then
        love.graphics.draw(img, sx + sw, sy, 0, -1, 1)
    else
        love.graphics.draw(img, sx, sy)
    end
    love.graphics.setColor(1, 1, 1)

    -- A little name tag over remote players.
    if not self.is_local and self.name then
        local font = love.graphics.getFont()
        local tw = font:getWidth(self.name)
        local cx = self.x + self.w / 2
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", cx - tw / 2 - 2, self.y - 12, tw + 4, 11)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(self.name, cx - tw / 2, self.y - 12)
    end
end

return Player
