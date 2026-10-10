-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Enemies, items, fireballs and cosmetic effects.
--
-- Everything here is deterministic given the shared world tick: walkers and
-- sliding shells are pure functions of the tick, while items and fireballs are
-- stepped forward from the tick that created them. Player collisions are only
-- resolved on the machine that owns the player; the resulting state change is
-- broadcast so every client converges.

local Config = require("config")
local Sprites = require("sprites")

local Entities = {}
Entities.__index = Entities

local T = require("level").T
local TILE = Config.TILE
local DT = Config.FIXED_DT

local BLOB_SPEED = 30
local TURTLE_SPEED = 36
local ITEM_SPEED = 44
local FIREBALL_SPEED = Config.FIREBALL_SPEED
local FIREBALL_GRAVITY = 1100
local FIREBALL_BOUNCE = 210

local function aabb(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

function Entities.new(level, on_emit)
    local self = setmetatable({}, Entities)
    self.level = level
    self.on_emit = on_emit
    self.enemies = {}
    self.items = {}
    self.fireballs = {}
    self.effects = {}
    self.next_fireball = 1
    self:reset()
    return self
end

function Entities:emit(message)
    if self.on_emit then self.on_emit(message) end
end

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

function Entities:reset()
    self.enemies = {}
    for i, def in ipairs(self.level.enemies) do
        local turtle = def.kind == "turtle"
        self.enemies[i] = {
            index = i,
            kind = def.kind,
            birth_tick = 0,
            xmin = def.xmin,
            xmax = def.xmax,
            base_y = def.baseY + (turtle and 0 or 2),
            speed = turtle and TURTLE_SPEED or BLOB_SPEED,
            x = def.baseX,
            y = def.baseY + (turtle and 0 or 2),
            w = 14,
            h = turtle and 16 or 14,
            dir = -1,
            state = "walk",
            dead_tick = 0,
            kick_tick = 0,
            kick_x = 0,
            shell_dir = 1,
            owner = "0",
            anim = 0,
        }
    end
    self.items = {}
    self.fireballs = {}
    self.effects = {}
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

function Entities:flip_enemy(foe, tick, owner, vx)
    if foe.state == "gone" or foe.state == "flip" then return end
    foe.state = "flip"
    foe.dead_tick = tick
    foe.flip_x = foe.x
    foe.flip_y = foe.y
    foe.flip_vx = vx or 0
    foe.flip_vy = -190
    foe.owner = owner or "0"
end

function Entities:coin_pop(tx, ty)
    self.effects[#self.effects + 1] = {
        type = "coinpop", x = tx * TILE + 8, y = ty * TILE, t = 0,
    }
end

function Entities:score_pop(x, y, points)
    self.effects[#self.effects + 1] = {
        type = "score", x = x, y = y, t = 0, text = tostring(points),
    }
end

function Entities:debris(tx, ty)
    for i = 1, 4 do
        self.effects[#self.effects + 1] = {
            type = "debris", x = tx * TILE + 4 + (i % 2) * 8, y = ty * TILE + 4,
            vx = (i <= 2 and -60 or 60) + (i % 2) * 10,
            vy = -150 - (i % 2) * 40, t = 0,
        }
    end
end

----------------------------------------------------------------------
-- Blocks
----------------------------------------------------------------------

-- Idempotent: only the first call for a fresh block does anything, so the
-- broadcast echo of our own bump is harmless. Returns "coin", "item" or true
-- so the caller knows what (if anything) to award.
function Entities:apply_block_bump(tx, ty, pid, tick)
    local id = self.level:get(tx, ty)
    if id == T.QUESTION then
        local contents = self.level:contentsAt(tx, ty) or "coin"
        self.level:consumeContents(tx, ty)
        self.level:set(tx, ty, T.USED)
        if contents == "coin" then
            self:coin_pop(tx, ty)
            self:flip_enemies_on(tx, ty, pid, tick)
            return "coin"
        else
            self:spawn_item(tx, ty, contents, tick)
            self:flip_enemies_on(tx, ty, pid, tick)
            return "item"
        end
    elseif id == T.BRICK then
        local contents = self.level:contentsAt(tx, ty)
        if contents then
            self.level:consumeContents(tx, ty)
            self:coin_pop(tx, ty)
            self:flip_enemies_on(tx, ty, pid, tick)
            return "coin"
        end
        self:flip_enemies_on(tx, ty, pid, tick)
        return true
    end
    return false
end

function Entities:break_brick(tx, ty)
    if self.level:get(tx, ty) == T.BRICK then
        self.level:set(tx, ty, T.EMPTY)
        self:debris(tx, ty)
        return true
    end
    return false
end

function Entities:flip_enemies_on(tx, ty, pid, tick)
    local left = tx * TILE
    local right = left + TILE
    local top = ty * TILE
    for _, foe in pairs(self.enemies) do
        if foe.state == "walk" and math.abs((foe.base_y + foe.h) - top) <= 2
            and foe.x < right and foe.x + foe.w > left then
            local dir = foe.x < left and -1 or 1
            self:flip_enemy(foe, tick, pid, dir * 50)
        end
    end
end

----------------------------------------------------------------------
-- Items
----------------------------------------------------------------------

function Entities:spawn_item(tx, ty, kind, tick)
    local key = tx .. "," .. ty
    if self.items[key] then return end
    local item = {
        key = key, kind = kind, tx = tx, ty = ty,
        x = tx * TILE, y = ty * TILE, w = 16, h = 16,
        vx = 0, vy = 0, dir = 1, on_ground = false,
        spawn_tick = tick or 0, state = "emerge",
        rest_y = ty * TILE - 16,
    }
    self.items[key] = item
end

function Entities:remove_item(key, pid)
    local item = self.items[key]
    if not item then return end
    self.items[key] = nil
    if pid then self:score_pop(item.x + 8, item.y, 0) end
end

function Entities:step_item(it, tick, dt)
    if it.state == "emerge" then
        local n = tick - it.spawn_tick
        local total = 22
        if n < 0 then n = 0 end
        if n >= total then
            it.y = it.rest_y
            if it.kind == "flower" then
                it.state = "static"
            elseif it.kind == "star" then
                it.state = "bounce"
                it.bounce_t = 0
            else
                it.state = "walk"
                it.on_ground = true
            end
        else
            it.y = it.ty * TILE - (n / total) * 16
        end
        return
    end

    if it.state == "static" then return end

    if it.state == "bounce" then
        it.bounce_t = (it.bounce_t or 0) + dt * 3
        it.y = it.rest_y - math.abs(math.sin(it.bounce_t)) * 34
        return
    end

    if it.state == "walk" then
        local level = self.level
        it.vy = it.vy + Config.GRAVITY * dt
        if it.vy > Config.MAX_FALL_SPEED then it.vy = Config.MAX_FALL_SPEED end
        -- Horizontal with wall turn-around.
        local nx = it.x + it.dir * ITEM_SPEED * dt
        local ty1 = math.floor(it.y / TILE)
        local ty2 = math.floor((it.y + it.h - 1) / TILE)
        local blocked = false
        if it.dir > 0 then
            local tx = math.floor((nx + it.w - 1) / TILE)
            for yy = ty1, ty2 do
                if level:solid(tx, yy) then blocked = true end
            end
        else
            local tx = math.floor(nx / TILE)
            for yy = ty1, ty2 do
                if level:solid(tx, yy) then blocked = true end
            end
        end
        if blocked then it.dir = -it.dir else it.x = nx end
        -- Vertical.
        it.y = it.y + it.vy * dt
        local x1 = math.floor(it.x / TILE)
        local x2 = math.floor((it.x + it.w - 1) / TILE)
        if it.vy > 0 then
            local ty = math.floor((it.y + it.h - 1) / TILE)
            for xx = x1, x2 do
                if level:solid(xx, ty) then
                    it.y = ty * TILE - it.h
                    it.vy = 0
                    it.on_ground = true
                    break
                end
            end
        else
            local ty = math.floor(it.y / TILE)
            for xx = x1, x2 do
                if level:solid(xx, ty) then
                    it.y = (ty + 1) * TILE
                    it.vy = 0
                    break
                end
            end
        end
        if it.y > level.pixelHeight + 64 then self.items[it.key] = nil end
    end
end

----------------------------------------------------------------------
-- Fireballs
----------------------------------------------------------------------

function Entities:spawn_fireball(x, y, dir, owner, tick)
    local key = "fb" .. self.next_fireball
    self.next_fireball = self.next_fireball + 1
    self.fireballs[key] = {
        key = key, x = x, y = y, w = 8, h = 8,
        vx = FIREBALL_SPEED * dir, vy = 0, dir = dir,
        owner = owner, birth_tick = tick or 0, age = 0,
    }
end

function Entities:step_fireball(fb, tick, dt)
    local level = self.level
    fb.age = fb.age + dt
    if fb.age > 3 or math.abs(fb.x) > level.pixelWidth + 64 then
        self.fireballs[fb.key] = nil
        return
    end
    fb.vy = fb.vy + FIREBALL_GRAVITY * dt
    if fb.vy > Config.MAX_FALL_SPEED then fb.vy = Config.MAX_FALL_SPEED end
    -- Horizontal.
    local nx = fb.x + fb.vx * dt
    local ty1 = math.floor(fb.y / TILE)
    local ty2 = math.floor((fb.y + fb.h - 1) / TILE)
    local blocked = false
    if fb.vx > 0 then
        local tx = math.floor((nx + fb.w - 1) / TILE)
        for yy = ty1, ty2 do
            if level:solid(tx, yy) then blocked = true end
        end
    else
        local tx = math.floor(nx / TILE)
        for yy = ty1, ty2 do
            if level:solid(tx, yy) then blocked = true end
        end
    end
    if blocked then
        self.fireballs[fb.key] = nil
        return
    end
    fb.x = nx
    -- Vertical.
    fb.y = fb.y + fb.vy * dt
    local x1 = math.floor(fb.x / TILE)
    local x2 = math.floor((fb.x + fb.w - 1) / TILE)
    if fb.vy > 0 then
        local ty = math.floor((fb.y + fb.h - 1) / TILE)
        for xx = x1, x2 do
            if level:solid(xx, ty) then
                fb.y = ty * TILE - fb.h
                fb.vy = -FIREBALL_BOUNCE
                break
            end
        end
    else
        local ty = math.floor(fb.y / TILE)
        for xx = x1, x2 do
            if level:solid(xx, ty) then
                fb.y = (ty + 1) * TILE
                fb.vy = 0
                break
            end
        end
    end
end

----------------------------------------------------------------------
-- Simulation
----------------------------------------------------------------------

function Entities:step_enemy(foe, tick, world)
    if foe.state == "gone" then return end
    foe.anim = foe.anim + 1

    if foe.state == "walk" then
        local span = math.max(8, foe.xmax - foe.xmin)
        local d = (tick - foe.birth_tick) * foe.speed / Config.TICKRATE
        local p = d % (2 * span)
        if p <= span then
            foe.x = foe.xmin + p
            foe.dir = 1
        else
            foe.x = foe.xmin + (2 * span - p)
            foe.dir = -1
        end
        foe.y = foe.base_y
    elseif foe.state == "squish" then
        foe.y = foe.base_y
        if tick - foe.dead_tick > 30 then foe.state = "gone" end
    elseif foe.state == "shell" then
        -- stationary
    elseif foe.state == "slide" then
        local span = math.max(8, foe.xmax - foe.xmin)
        local two = 2 * span
        local raw = (foe.kick_x - foe.xmin)
            + (tick - foe.kick_tick) * Config.SHELL_SPEED / Config.TICKRATE * foe.shell_dir
        local p = raw % two
        if p < 0 then p = p + two end
        if p <= span then
            foe.x = foe.xmin + p
            foe.dir = 1
        else
            foe.x = foe.xmin + (2 * span - p)
            foe.dir = -1
        end
        foe.y = foe.base_y
    elseif foe.state == "flip" then
        local n = (tick - foe.dead_tick) / Config.TICKRATE
        foe.x = foe.flip_x + foe.flip_vx * n
        foe.y = foe.flip_y + foe.flip_vy * n + 0.5 * Config.GRAVITY * n * n
        if foe.y > self.level.pixelHeight + 96 then foe.state = "gone" end
    end
end

function Entities:shell_collisions(tick)
    for _, shell in pairs(self.enemies) do
        if shell.state == "slide" then
            for _, other in pairs(self.enemies) do
                if other ~= shell and other.state == "walk"
                    and aabb(shell.x, shell.y, shell.w, shell.h,
                        other.x, other.y, other.w, other.h) then
                    self:flip_enemy(other, tick, shell.owner or "0", shell.dir * 70)
                    self:emit(("~E|%d|%s|flip|%.1f|%d|%d"):format(
                        other.index, shell.owner or "0", other.x, tick, shell.dir * 70))
                end
            end
        end
    end
end

function Entities:fireball_collisions(tick)
    for _, fb in pairs(self.fireballs) do
        -- Only the owner resolves hits; everyone else applies the "~E" event.
        if not self.local_pid or fb.owner == self.local_pid then
            for _, foe in pairs(self.enemies) do
                if foe.state == "walk"
                    and aabb(fb.x, fb.y, fb.w, fb.h, foe.x, foe.y, foe.w, foe.h) then
                    self:flip_enemy(foe, tick, fb.owner, fc_dir(fb))
                    self:emit(("~E|%d|%s|flip|%.1f|%d|%d"):format(
                        foe.index, fb.owner, foe.x, tick, fc_dir(fb)))
                    self.fireballs[fb.key] = nil
                    break
                end
            end
        end
    end
end

function fc_dir(fb)
    return fb.vx >= 0 and 70 or -70
end

function Entities:player_collisions(world, tick)
    for _, p in ipairs(world.players) do
        if p.is_local and p.alive and not p.goal then
            self:collide_player_with_enemies(world, p, tick)
            self:collide_player_with_items(world, p, tick)
            self:collide_player_with_coins(world, p)
        end
    end
end

function Entities:collide_player_with_enemies(world, p, tick)
    for _, foe in pairs(self.enemies) do
        if foe.state ~= "gone" and foe.state ~= "flip" and foe.state ~= "squish"
            and aabb(p.x, p.y, p.w, p.h, foe.x, foe.y, foe.w, foe.h) then
            local stomp = p.vy > 0 and (p.y + p.h) <= foe.y + foe.h * 0.7
            if p.star and p.star > 0 then
                self:flip_enemy(foe, tick, p.id_str, fc_dir({ vx = p.vx }))
                self:emit(("~E|%d|%s|flip|%.1f|%d|%d"):format(
                    foe.index, p.id_str, foe.x, tick, fc_dir({ vx = p.vx })))
                world:award(p, 200)
            elseif stomp then
                world:stomp_enemy(p, foe, tick)
            elseif foe.state == "shell" then
                local dir = (p.x + p.w / 2) < (foe.x + foe.w / 2) and 1 or -1
                foe.state = "slide"
                foe.kick_x = foe.x
                foe.kick_tick = tick
                foe.shell_dir = dir
                foe.owner = p.id_str
                self:emit(("~K|%d|%s|%d|%.1f|%d"):format(
                    foe.index, p.id_str, dir, foe.x, tick))
            elseif foe.state == "slide" then
                world:player_hurt(p, foe, tick)
            else
                world:player_hurt(p, foe, tick)
            end
            return
        end
    end
end

function Entities:collide_player_with_items(world, p, tick)
    for key, item in pairs(self.items) do
        if item.state ~= "emerge" or (tick - item.spawn_tick) > 6 then
            if aabb(p.x, p.y, p.w, p.h, item.x, item.y, item.w, item.h) then
                self:collect_item(key, p, world)
            end
        end
    end
end

function Entities:collide_player_with_coins(world, p)
    for _, coin in ipairs(self.level.coins) do
        if not coin.collected
            and aabb(p.x, p.y, p.w, p.h, coin.px - 6, coin.py - 6, 12, 12) then
            coin.collected = true
            world:collect_coin(p, coin)
        end
    end
end

function Entities:collect_item(key, p, world)
    local item = self.items[key]
    if not item then return end
    self.items[key] = nil
    world:apply_item(p, item)
    if world.net then
        world.net:send(("~I|%d|%d|%s"):format(item.tx, item.ty, p.id_str))
    end
end

function Entities:step(tick, world)
    self.tick = tick
    for _, foe in pairs(self.enemies) do
        self:step_enemy(foe, tick, world)
    end
    for _, it in pairs(self.items) do
        self:step_item(it, tick, DT)
    end
    for _, fb in pairs(self.fireballs) do
        self:step_fireball(fb, tick, DT)
    end
    self:shell_collisions(tick)
    self:fireball_collisions(tick)
    if world then self:player_collisions(world, tick) end
    self:step_effects(DT)
end

function Entities:step_effects(dt)
    for i = #self.effects, 1, -1 do
        local e = self.effects[i]
        e.t = e.t + dt
        if e.type == "debris" then
            e.vy = e.vy + Config.GRAVITY * dt
            e.x = e.x + e.vx * dt
            e.y = e.y + e.vy * dt
            if e.t > 1.2 then table.remove(self.effects, i) end
        elseif e.type == "coinpop" then
            if e.t > 0.4 then table.remove(self.effects, i) end
        elseif e.type == "score" then
            e.y = e.y - 22 * dt
            if e.t > 0.8 then table.remove(self.effects, i) end
        end
    end
end

----------------------------------------------------------------------
-- Network event application
----------------------------------------------------------------------

function Entities:enemy_event(event)
    local foe = self.enemies[event.index]
    if not foe then return end
    local x = event.x or foe.x
    local tick = event.tick or self.tick or 0
    if event.mode == "squish" then
        if foe.state == "walk" then
            foe.x, foe.y = x, foe.base_y
            foe.state = "squish"
            foe.dead_tick = tick
        end
    elseif event.mode == "shell" then
        if foe.state == "walk" then
            foe.x, foe.y = x, foe.base_y
            foe.state = "shell"
            foe.dead_tick = tick
            foe.kick_tick = 0
        end
    elseif event.mode == "flip" then
        if foe.state ~= "gone" and foe.state ~= "flip" then
            foe.x, foe.y = x, foe.y
            self:flip_enemy(foe, tick, event.pid, event.vx or 0)
        end
    end
end

function Entities:kick_event(event)
    local foe = self.enemies[event.index]
    if not foe then return end
    if foe.state == "shell" or foe.state == "slide" then
        foe.state = "slide"
        foe.kick_x = event.x
        foe.kick_tick = event.tick
        foe.shell_dir = event.dir
        foe.owner = event.pid
    end
end

function Entities:fireball_event(event)
    self:spawn_fireball(event.x, event.y, event.dir, event.pid, event.tick)
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local function draw_sprite(name, x, y, sx, sy)
    local img = Sprites.get(name)
    if not img then return end
    if sy and sy < 0 then
        love.graphics.draw(img, x + img:getWidth(), y + img:getHeight(), 0, sx or 1, -1)
    else
        love.graphics.draw(img, x, y, 0, sx or 1, sy or 1)
    end
end

function Entities:draw(camera, tick)
    -- Items.
    for _, item in pairs(self.items) do
        local name = item.kind == "mushroom" and "mushroom"
            or item.kind == "1up" and "oneup"
            or item.kind
        draw_sprite(name, item.x - 1, item.y)
    end

    -- Fireballs.
    for _, fb in pairs(self.fireballs) do
        local frame = 1 + (math.floor(tick / 4) % 2)
        draw_sprite("fireball", fb.x - 4, fb.y - 4, 1, 1)
    end

    -- Enemies.
    for _, foe in pairs(self.enemies) do
        if foe.state == "walk" then
            local name = foe.kind == "turtle"
                and ((math.floor(tick / 10) % 2 == 0) and "turtle1" or "turtle2")
                or ((math.floor(tick / 12) % 2 == 0) and "blob1" or "blob2")
            local dx = foe.x - 1
            local dy = foe.y - (foe.kind == "turtle" and 0 or 2)
            if foe.dir and foe.dir < 0 then
                draw_sprite(name, dx, dy, -1, 1)
            else
                draw_sprite(name, dx, dy, 1, 1)
            end
        elseif foe.state == "squish" then
            draw_sprite("blob_flat", foe.x - 1, foe.y - 2)
        elseif foe.state == "shell" or foe.state == "slide" then
            local name = "shell"
            if foe.state == "slide" and math.floor(tick / 4) % 2 == 0 then
                name = "shell"
            end
            draw_sprite(name, foe.x - 1, foe.y - 4)
        elseif foe.state == "flip" then
            local name = foe.kind == "turtle" and "turtle1" or "blob1"
            draw_sprite(name, foe.x - 1, foe.y - 2, 1, -1)
        end
    end

    -- Effects.
    for _, e in ipairs(self.effects) do
        if e.type == "coinpop" then
            local frame = 1 + (math.floor(e.t * 20) % 3)
            draw_sprite("coin" .. frame, e.x - 8, e.y - (e.t * 90))
        elseif e.type == "debris" then
            love.graphics.setColor(0.55, 0.30, 0.10)
            love.graphics.rectangle("fill", e.x, e.y, 4, 4)
            love.graphics.setColor(1, 1, 1)
        elseif e.type == "score" then
            if love.graphics.getFont() then
                love.graphics.setColor(1, 1, 1)
                love.graphics.print(e.text, e.x, e.y)
            end
        end
    end
end

return Entities
