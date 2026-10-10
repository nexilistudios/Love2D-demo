-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Level 1. The level is built from tiles by code so it stays readable and
-- easy to tweak. Tile coordinates are 0-based; one tile is 16x16 world pixels.

local Config = require("config")
local Sprites = require("sprites")

local Level = {}
Level.__index = Level

-- Tile ids.
Level.T = {
    EMPTY = 0,
    GROUND = 1,
    BRICK = 2,
    QUESTION = 3,
    USED = 4,
    SOLID = 5,
    PIPE_TL = 6,
    PIPE_TR = 7,
    PIPE_BL = 8,
    PIPE_BR = 9,
    POLE = 10,
    POLE_TOP = 11,
}

-- Which tiles block movement.
local SOLID = {
    [Level.T.GROUND] = true,
    [Level.T.BRICK] = true,
    [Level.T.QUESTION] = true,
    [Level.T.USED] = true,
    [Level.T.SOLID] = true,
    [Level.T.PIPE_TL] = true,
    [Level.T.PIPE_TR] = true,
    [Level.T.PIPE_BL] = true,
    [Level.T.PIPE_BR] = true,
}

-- Which tile ids can be bumped from below.
local BUMPABLE = {
    [Level.T.BRICK] = true,
    [Level.T.QUESTION] = true,
}

Level.WIDTH = 214
Level.HEIGHT = 15
Level.GROUND_TOP = 13 -- first ground row; ground occupies rows 13 and 14

local T = Level.T

function Level.build()
    local self = setmetatable({}, Level)
    self.w = Level.WIDTH
    self.h = Level.HEIGHT
    self.tiles = {}
    for y = 0, self.h - 1 do
        self.tiles[y] = {}
        for x = 0, self.w - 1 do
            self.tiles[y][x] = T.EMPTY
        end
    end

    -- Contents of ? blocks and hidden items, keyed by "x,y".
    self.contents = {}
    self.coins = {} -- floating coins: {tx, ty}
    self.enemies = {}
    self.decor = {}

    local function set(x, y, id)
        if x >= 0 and x < self.w and y >= 0 and y < self.h then
            self.tiles[y][x] = id
        end
    end

    local function ground(x1, x2)
        for x = x1, x2 do
            set(x, 13, T.GROUND)
            set(x, 14, T.GROUND)
        end
    end

    local function row(y, x1, x2, id)
        for x = x1, x2 do set(x, y, id) end
    end

    local function pipe(x, height)
        local top = 13 - height
        set(x, top, T.PIPE_TL)
        set(x + 1, top, T.PIPE_TR)
        for y = top + 1, 12 do
            set(x, y, T.PIPE_BL)
            set(x + 1, y, T.PIPE_BR)
        end
    end

    local function question(x, y, item)
        set(x, y, T.QUESTION)
        self.contents[x .. "," .. y] = item or "coin"
    end

    local function brick(x, y, item)
        set(x, y, T.BRICK)
        if item then self.contents[x .. "," .. y] = item end
    end

    local function coin(x, y)
        self.coins[#self.coins + 1] = { tx = x, ty = y }
    end

    local function enemy(kind, x, y)
        self.enemies[#self.enemies + 1] = { kind = kind, tx = x, ty = y }
    end

    -- ---------------------------------------------------------------
    -- Ground
    -- ---------------------------------------------------------------
    ground(0, 68)
    ground(71, 85)
    ground(89, 152)
    ground(156, 211)

    -- ---------------------------------------------------------------
    -- Opening: first ? block, the four-block group and the high bricks
    -- ---------------------------------------------------------------
    question(16, 9, "mushroom")

    brick(20, 9)
    question(21, 9, "coin")
    brick(22, 9)
    question(23, 9, "coin")
    brick(24, 9)

    brick(20, 5)
    brick(21, 5)
    question(22, 5, "star")
    brick(23, 5)
    brick(24, 5)

    coin(15, 8)
    coin(17, 8)

    -- ---------------------------------------------------------------
    -- Pipes
    -- ---------------------------------------------------------------
    pipe(28, 2)
    pipe(38, 3)
    pipe(46, 4)
    pipe(57, 4)

    -- ---------------------------------------------------------------
    -- Enemies around the opening
    -- ---------------------------------------------------------------
    enemy("blob", 22, 12)
    enemy("blob", 40, 12)
    enemy("blob", 51, 12)
    enemy("blob", 53, 12)
    enemy("turtle", 60, 12)

    -- ---------------------------------------------------------------
    -- Middle section: bricks, coins, more pipes
    -- ---------------------------------------------------------------
    brick(64, 9)
    question(65, 9, "coin")
    brick(66, 9)

    for x = 77, 79 do brick(x, 9) end
    question(80, 9, "mushroom")

    coin(84, 7)
    coin(85, 7)
    coin(86, 7)

    pipe(92, 3)
    pipe(101, 2)

    brick(106, 9)
    brick(107, 9)
    question(108, 9, "coin")
    brick(109, 9)

    brick(106, 5)
    brick(107, 5)
    question(108, 5, "flower")
    brick(109, 5)

    enemy("blob", 88, 12)
    enemy("blob", 90, 12)
    enemy("blob", 104, 12)
    enemy("blob", 106, 12)
    enemy("turtle", 118, 12)
    enemy("blob", 126, 12)
    enemy("blob", 128, 12)

    -- ---------------------------------------------------------------
    -- Raised stretch with a small staircase
    -- ---------------------------------------------------------------
    for i = 0, 3 do
        row(13 - 1 - i, 133 + i, 133 + i, T.SOLID)
        row(13 - 1 - i, 136 - i, 136 - i, T.SOLID)
    end

    question(140, 9, "coin")
    question(141, 9, "coin")
    question(142, 9, "coin")

    coin(145, 7)
    coin(146, 7)

    pipe(150, 2)

    -- ---------------------------------------------------------------
    -- Final stretch and the big staircase
    -- ---------------------------------------------------------------
    brick(160, 9)
    brick(161, 9)
    brick(162, 9)
    question(163, 9, "1up")
    brick(164, 9)

    enemy("blob", 158, 12)
    enemy("turtle", 165, 12)

    -- Ascending staircase (8 steps).
    for i = 0, 7 do
        for j = 0, i do
            set(181 + i, 12 - j, T.SOLID)
        end
    end
    -- Descending back down.
    for i = 0, 7 do
        for j = 0, (7 - i) do
            set(190 + i, 12 - j, T.SOLID)
        end
    end

    -- ---------------------------------------------------------------
    -- Flagpole and castle
    -- ---------------------------------------------------------------
    self.flagpoleTx = 198
    set(198, 3, T.POLE_TOP)
    for y = 4, 12 do set(198, y, T.POLE) end

    self.castleTx = 199
    self.goalTx = 198

    -- A few decorative bushes/hills/clouds.
    for _, d in ipairs({
        { "hill", 0, 3 }, { "bush", 11, 12 }, { "cloud", 8, 3 },
        { "hill", 16, 3 }, { "bush", 23, 12 }, { "cloud", 19, 2 },
        { "cloud", 27, 4 }, { "bush", 41, 12 }, { "hill", 47, 3 },
        { "cloud", 36, 3 }, { "cloud", 56, 2 }, { "bush", 71, 12 },
        { "hill", 64, 3 }, { "cloud", 75, 4 }, { "cloud", 96, 2 },
        { "bush", 96, 12 }, { "hill", 112, 3 }, { "cloud", 118, 3 },
        { "bush", 130, 12 }, { "cloud", 140, 2 }, { "hill", 155, 3 },
        { "cloud", 160, 4 }, { "bush", 172, 12 }, { "cloud", 185, 3 },
    }) do
        self.decor[#self.decor + 1] = { kind = d[1], tx = d[2], ty = d[3] }
    end

    self.pixelWidth = self.w * Config.TILE
    self.pixelHeight = self.h * Config.TILE

    self:prepareEntities()
    return self
end

function Level:get(tx, ty)
    if ty < 0 or ty >= self.h then return T.EMPTY end
    -- Solid walls beyond the left/right edges keep players in the level.
    if tx < 0 then return T.SOLID end
    if tx >= self.w then return T.SOLID end
    return self.tiles[ty][tx]
end

function Level:set(tx, ty, id)
    if tx >= 0 and tx < self.w and ty >= 0 and ty < self.h then
        self.tiles[ty][tx] = id
    end
end

function Level:solid(tx, ty)
    return SOLID[self:get(tx, ty)] == true
end

function Level:bumpable(tx, ty)
    return BUMPABLE[self:get(tx, ty)] == true
end

function Level:contentsAt(tx, ty)
    return self.contents[tx .. "," .. ty]
end

function Level:consumeContents(tx, ty)
    self.contents[tx .. "," .. ty] = nil
end

----------------------------------------------------------------------
-- Entity preparation
----------------------------------------------------------------------

-- Walk left/right from (tx, ty) while the tile below is ground and the tile
-- itself is not solid. Returns the pixel range the entity may patrol.
function Level:patrolRange(tx, ty)
    local left = tx
    while left > 0
        and not self:solid(left - 1, ty)
        and self:solid(left - 1, ty + 1) do
        left = left - 1
    end
    local right = tx
    while right < self.w - 1
        and not self:solid(right + 1, ty)
        and self:solid(right + 1, ty + 1) do
        right = right + 1
    end
    return left * Config.TILE, right * Config.TILE
end

function Level:prepareEntities()
    -- Coins get stable indices; used by the network protocol.
    for i, c in ipairs(self.coins) do
        c.index = i
        c.px = c.tx * Config.TILE + Config.TILE / 2
        c.py = c.ty * Config.TILE + Config.TILE / 2
        c.collected = false
    end

    for i, e in ipairs(self.enemies) do
        e.index = i
        local xmin, xmax = self:patrolRange(e.tx, e.ty)
        e.xmin = xmin
        e.xmax = xmax
        e.baseX = e.tx * Config.TILE
        e.baseY = e.ty * Config.TILE
        e.px = e.baseX
        e.py = e.baseY
        e.kind = e.kind or "blob"
        local turtle = e.kind == "turtle"
        e.w = 16
        e.h = turtle and 24 or 16
        -- Turtle sprites are drawn shorter than 24; keep hitbox at 16 for now.
        e.h = 16
        e.y = e.ty * Config.TILE + (Config.TILE - 16)
        e.dir = -1
        e.state = "walk" -- walk | squish | shell | slide | dead
        e.deadTimer = 0
        e.spawnTick = 0
        e.kickTick = 0
        e.shellDir = 1
    end
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local function triangle(t, period)
    -- Returns a value in [0, 1] that goes up then down with the given period.
    if period <= 0 then return 0 end
    local p = (t % period) / period
    return 1 - math.abs(p * 2 - 1)
end

function Level:drawBackground(camera)
    local g = love.graphics
    -- Sky is cleared by the caller; draw the rolling hills, bushes and clouds.
    for _, d in ipairs(self.decor) do
        local px = d.tx * Config.TILE
        local py = d.ty * Config.TILE
        if px > camera.x - 260 and px < camera.x + 460 then
            if d.kind == "cloud" then
                self:drawCloud(px, py)
            elseif d.kind == "hill" then
                self:drawHill(px, py)
            elseif d.kind == "bush" then
                self:drawBush(px, py)
            end
        end
    end
    g.setColor(1, 1, 1, 1)
end

function Level:drawCloud(px, py)
    local g = love.graphics
    g.setColor(1, 1, 1)
    g.rectangle("fill", px, py, 48, 12)
    g.rectangle("fill", px + 6, py - 8, 36, 10)
    g.rectangle("fill", px + 14, py - 14, 20, 10)
end

function Level:drawHill(px, py)
    local g = love.graphics
    g.setColor(0.20, 0.66, 0.24)
    for i = 0, 12 do
        g.rectangle("fill", px + i * 4, py + 48 - (i + 1) * 4, 4, (i + 1) * 4)
        g.rectangle("fill", px + 48 - i * 4, py + 48 - (i + 1) * 4, 4, (i + 1) * 4)
    end
end

function Level:drawBush(px, py)
    local g = love.graphics
    g.setColor(0.22, 0.70, 0.26)
    g.rectangle("fill", px, py, 40, 16)
    g.rectangle("fill", px + 4, py - 8, 32, 12)
    g.rectangle("fill", px + 12, py - 14, 16, 10)
end

function Level:drawCastle(px, py)
    local g = love.graphics
    local brick = { 0.72, 0.34, 0.18 }
    g.setColor(brick)
    g.rectangle("fill", px, py + 16, 80, 48)
    g.rectangle("fill", px + 16, py, 48, 16)
    -- Battlements.
    for i = 0, 4 do
        g.rectangle("fill", px + i * 16, py - 8, 8, 8)
        g.rectangle("fill", px + 16 + i * 12, py - 8, 8, 8)
    end
    -- Door and windows.
    g.setColor(0.12, 0.08, 0.06)
    g.rectangle("fill", px + 32, py + 40, 16, 24)
    g.rectangle("fill", px + 20, py + 24, 8, 10)
    g.rectangle("fill", px + 52, py + 24, 8, 10)
    g.setColor(1, 1, 1)
end

function Level:drawTiles(camera)
    local g = love.graphics
    local tx0 = math.max(0, math.floor(camera.x / Config.TILE) - 1)
    local tx1 = math.min(self.w - 1, math.floor((camera.x + camera.w) / Config.TILE) + 1)
    local spriteFor = {
        [T.GROUND] = "ground",
        [T.BRICK] = "brick",
        [T.QUESTION] = "question",
        [T.USED] = "question_used",
        [T.SOLID] = "solid",
        [T.PIPE_TL] = "pipe_tl",
        [T.PIPE_TR] = "pipe_tr",
        [T.PIPE_BL] = "pipe_bl",
        [T.PIPE_BR] = "pipe_br",
        [T.POLE] = "pole",
        [T.POLE_TOP] = "pole",
    }
    for ty = 0, self.h - 1 do
        for tx = tx0, tx1 do
            local id = self.tiles[ty][tx]
            if id ~= T.EMPTY then
                local name = spriteFor[id]
                if name then
                    local img = Sprites.get(name)
                    if id == T.QUESTION then
                        -- Animate the ? blocks.
                        local frame = 1 + (math.floor(love.timer.getTime() * 4) % 4)
                        g.setColor(1, 1, 1)
                        g.draw(img, tx * Config.TILE, ty * Config.TILE, 0, 1, 1)
                        g.setColor(1, 0.85 + 0.15 * math.sin(frame), 0.3)
                        g.draw(img, tx * Config.TILE, ty * Config.TILE)
                        g.setColor(1, 1, 1)
                    else
                        g.draw(img, tx * Config.TILE, ty * Config.TILE)
                    end
                end
            end
        end
    end
    -- The castle sits at the end of the level.
    self:drawCastle(self.castleTx * Config.TILE, self.GROUND_TOP * Config.TILE - 48)
end

function Level:drawCoins(camera, tick)
    local g = love.graphics
    local frame = 1 + (math.floor(tick / 6) % 3)
    local img = Sprites.get("coin" .. frame)
    for _, c in ipairs(self.coins) do
        if not c.collected and c.px > camera.x - 32 and c.px < camera.x + camera.w + 32 then
            g.draw(img, c.px - 8, c.py - 8)
        end
    end
end

return Level
