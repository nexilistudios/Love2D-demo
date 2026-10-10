-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Love2D Platformer Demo - shared configuration and small helpers.
-- Everything is measured in "world pixels"; one tile is 16 world pixels.

local Config = {}

Config.TITLE = "Love2D Platformer Demo"
Config.WINDOW_WIDTH = 1280
Config.WINDOW_HEIGHT = 720
Config.SCALE = 3 -- one world pixel is drawn as 3x3 screen pixels

Config.TILE = 16
Config.TICKRATE = 60
Config.FIXED_DT = 1 / Config.TICKRATE

-- Server defaults (override the host with the NX_HOST env var).
Config.SERVER_ADDRESS = os.getenv("NX_HOST") or "127.0.0.1"
Config.SERVER_PASSWORD = os.getenv("NX_PASSWORD") or ""

-- Physics. Tuned to feel close to classic 8/16-bit platformers.
Config.GRAVITY = 1900
Config.MAX_FALL_SPEED = 560
Config.WALK_ACCEL = 620
Config.RUN_ACCEL = 900
Config.FRICTION = 820
Config.MAX_WALK_SPEED = 96
Config.MAX_RUN_SPEED = 168
Config.JUMP_VELOCITY = 372
Config.JUMP_HOLD_GRAVITY = 0.42 -- gravity multiplier while jump is held & rising
Config.STOMP_BOUNCE = 250
Config.ENEMY_SPEED = 30
Config.SHELL_SPEED = 150
Config.FIREBALL_SPEED = 220

-- Characters. The first is the default; players cycle with TAB on the title
-- screen. index is sent over the network inside the player state.
Config.CHARACTERS = {
    { name = "Red", primary = { 0.86, 0.16, 0.14 }, secondary = { 0.16, 0.30, 0.84 } },
    { name = "Green", primary = { 0.18, 0.68, 0.22 }, secondary = { 0.16, 0.30, 0.84 } },
    { name = "Yellow", primary = { 0.95, 0.80, 0.10 }, secondary = { 0.60, 0.20, 0.70 } },
    { name = "Blue",  primary = { 0.20, 0.45, 0.95 }, secondary = { 0.92, 0.92, 0.92 } },
    { name = "Pink", primary = { 0.95, 0.45, 0.75 }, secondary = { 0.85, 0.20, 0.55 } },
    { name = "Orange", primary = { 0.85, 0.45, 0.10 }, secondary = { 0.45, 0.70, 0.20 } },
}

-- Palette used by the pixel-art sprite maps. Keys are ASCII characters.
Config.PALETTE = {
    ["1"] = { 1.00, 1.00, 1.00 }, -- replaced per character (primary)
    ["2"] = { 0.16, 0.30, 0.84 }, -- replaced per character (secondary)
    ["3"] = { 0.98, 0.69, 0.47 }, -- skin
    ["4"] = { 0.48, 0.24, 0.06 }, -- hair / moustache / shoes
    ["5"] = { 0.98, 0.98, 0.98 }, -- white (eyes, gloves)
    ["6"] = { 0.08, 0.08, 0.08 }, -- outline / black
    ["7"] = { 0.98, 0.82, 0.12 }, -- buttons
    ["8"] = { 0.62, 0.32, 0.12 }, -- blob body
    ["9"] = { 0.86, 0.62, 0.36 }, -- blob feet / lighter brown
    ["a"] = { 0.28, 0.62, 0.30 }, -- turtle shell green
    ["b"] = { 0.94, 0.90, 0.45 }, -- turtle skin / shell belly
    ["c"] = { 0.90, 0.30, 0.20 }, -- mushroom cap red
    ["d"] = { 0.95, 0.75, 0.20 }, -- coin / question block
    ["e"] = { 0.55, 0.30, 0.10 }, -- block shadow / brick
    ["f"] = { 0.30, 0.78, 0.30 }, -- pipe green
    ["g"] = { 0.10, 0.52, 0.16 }, -- pipe dark green
    ["h"] = { 0.45, 0.75, 1.00 }, -- sky / water / ice
    ["i"] = { 0.98, 0.98, 0.98 }, -- cloud white (same as 5)
    ["j"] = { 0.20, 0.85, 0.35 }, -- 1-up / leaf green
    ["k"] = { 0.90, 0.90, 0.10 }, -- star
}

-- Convenience math helpers.
function Config.sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 else return 0 end
end

function Config.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

function Config.lerp(a, b, t)
    return a + (b - a) * t
end

return Config
