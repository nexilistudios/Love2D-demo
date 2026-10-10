-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Love2D Platformer Demo - entry point.
--
-- A tiny state machine drives the title screen, the (briefly blocking)
-- connection to the dedicated Nexilis server, and the game itself. Chat and
-- character selection live here; everything else is in world.lua.

local Config = require("config")
local Sprites = require("sprites")
local Net = require("net")
local World = require("world")
local Player = require("player")

local game = {
    state = "title", -- title | connecting | playing | error
    char = 1,
    name = os.getenv("LPD_NAME") or ("Player" .. tostring(math.random(1000, 9999))),
    net = nil,
    world = nil,
    error = nil,
    chat_active = false,
    chat_text = "",
    title_time = 0,
}

local function load_font()
    local size = 16
    local ok, font = pcall(love.graphics.newFont, size)
    if ok and font then love.graphics.setFont(font) end
end

function love.load()
    love.graphics.setDefaultFilter("nearest", "nearest")
    love.graphics.setBackgroundColor(0.36, 0.56, 0.95)
    if love.window and love.window.setMode then
        love.window.setMode(Config.WINDOW_WIDTH, Config.WINDOW_HEIGHT,
            { resizable = true, minwidth = 640, minheight = 360, vsync = 1 })
    end
    Sprites.build()
    load_font()
    game.title_time = 0

    -- Headless / integration testing helpers.
    local autostart = os.getenv("LPD_AUTOSTART")
    if autostart and autostart ~= "" and autostart ~= "0" then
        if os.getenv("LPD_CHAR") then
            local n = tonumber(os.getenv("LPD_CHAR"))
            if n and n >= 1 and n <= #Config.CHARACTERS then game.char = n end
        end
        start_connect()
    end
    game.test_seconds = tonumber(os.getenv("LPD_TEST_SECONDS") or "") or 0
    game.test_elapsed = 0
    game.finishing = false
    game.quit_at = nil
    game.debug = os.getenv("LPD_DEBUG") == "1"
    game.debug_timer = 0
end

local function print_summary()
    if not game.world then return end
    print(("[test] exiting after %.1fs in state %s"):format(game.test_elapsed, game.state))
    local lp = game.world.local_player
    print(("[test] local packed z=%.0f action=%s alive=%s power=%d"):format(
        Player.pack_state(lp), tostring(lp.action), tostring(lp.alive), lp.power))
    for _, p in ipairs(game.world.players) do
        print(("[test] player %-12s local=%-5s pos=(%.1f,%.1f) power=%d score=%d"):format(
            p.name, tostring(p.is_local), p.x, p.y, p.power, p.score))
    end
    local counts = {}
    for _, foe in pairs(game.world.entities.enemies) do
        counts[foe.state] = (counts[foe.state] or 0) + 1
    end
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    print("[test] enemies " .. table.concat(parts, " "))
    local items, fireballs = 0, 0
    for _ in pairs(game.world.entities.items) do items = items + 1 end
    for _ in pairs(game.world.entities.fireballs) do fireballs = fireballs + 1 end
    print(("[test] items=%d fireballs=%d"):format(items, fireballs))
    print(("[test] steps=%d over %.1fs (%.1f/s) fps=%d"):format(
        game.world.step_count, game.test_elapsed,
        game.world.step_count / math.max(0.001, game.test_elapsed), love.timer.getFPS()))
end

function love.update(dt)
    game.title_time = game.title_time + dt
    if game.state == "playing" and game.world then
        game.world:update(dt)
        if game.debug then
            game.debug_timer = game.debug_timer + dt
            if game.debug_timer >= 0.07 then
                game.debug_timer = 0
                local lp = game.world.local_player
                print(("[dbg] x=%.1f y=%.1f vx=%.1f vy=%.1f ground=%s act=%s jump=%s"):format(
                    lp.x, lp.y, lp.vx, lp.vy, tostring(lp.on_ground), tostring(lp.action),
                    tostring(game.world.input.jump)))
            end
        end
    end

    if game.test_seconds and game.test_seconds > 0 and not game.finishing then
        game.test_elapsed = game.test_elapsed + dt
        if game.test_elapsed >= game.test_seconds then
            game.finishing = true
            local shot = os.getenv("LPD_SCREENSHOT")
            if shot and shot ~= "" then
                love.graphics.captureScreenshot(function(imageData)
                    imageData:encode("png", shot)
                    print("[test] screenshot " .. love.filesystem.getSaveDirectory() .. "/" .. shot)
                end)
                game.quit_at = love.timer.getTime() + 0.4
            else
                game.quit_at = love.timer.getTime()
            end
        end
    end

    if game.finishing and game.quit_at and love.timer.getTime() >= game.quit_at then
        print_summary()
        love.event.quit(0)
    end
end

function love.draw()
    if game.state == "title" then
        draw_title()
    elseif game.state == "connecting" then
        draw_connecting()
    elseif game.state == "playing" then
        game.world:draw()
        draw_chat_box()
    elseif game.state == "error" then
        draw_error()
    end
end

----------------------------------------------------------------------
-- Title
----------------------------------------------------------------------

local controls = {
    "Arrows / A D  -  move",
    "Space / W     -  jump",
    "Shift         -  run",
    "B             -  throw fireball (fire power)",
    "T             -  chat",
    "TAB / 1..6    -  choose character",
    "ENTER         -  start",
}

function draw_title()
    local g = love.graphics
    g.clear(0.36, 0.56, 0.95)
    local W, H = g.getWidth(), g.getHeight()

    g.setColor(1, 0.95, 0.2)
    local title = "LOVE2D PLATFORMER DEMO"
    local font = g.getFont()
    g.print(title, (W - font:getWidth(title)) / 2, 60)

    g.setColor(1, 1, 1)
    g.print("Level 1  -  a cooperative platformer romp over a Nexilis server",
        (W - font:getWidth("Level 1  -  a cooperative platformer romp over a Nexilis server")) / 2, 92)

    -- Character preview with a gentle bob.
    local img = Sprites.player(game.char, "big", "idle")
    local bob = math.sin(game.title_time * 4) * 4
    if img then
        local s = 6
        g.setColor(1, 1, 1)
        g.draw(img, W / 2 - img:getWidth() * s / 2, 150 + bob, 0, s, s)
    end

    g.setColor(1, 1, 0.4)
    local cname = Config.CHARACTERS[game.char].name
    g.print(cname, (W - font:getWidth(cname)) / 2, 150 + 32 * 6 + 16)

    g.setColor(1, 1, 1)
    local y = 150 + 32 * 6 + 60
    for _, line in ipairs(controls) do
        g.print(line, (W - font:getWidth(line)) / 2, y)
        y = y + 18
    end

    g.setColor(0.9, 0.9, 0.9)
    local server = "Server: " .. Config.SERVER_ADDRESS
    g.print(server, (W - font:getWidth(server)) / 2, H - 40)

    g.setColor(1, 1, 0.6)
    local prompt = "Press ENTER to play"
    g.print(prompt, (W - font:getWidth(prompt)) / 2, H - 70)
    g.setColor(1, 1, 1)
end

----------------------------------------------------------------------
-- Connecting
----------------------------------------------------------------------

function draw_connecting()
    local g = love.graphics
    local W, H = g.getWidth(), g.getHeight()
    g.clear(0.16, 0.22, 0.4)
    g.setColor(1, 1, 1)
    g.print("Connecting to " .. Config.SERVER_ADDRESS .. "...", W / 2 - 100, H / 2 - 10)
end

function draw_error()
    local g = love.graphics
    local W = g.getWidth()
    g.clear(0.3, 0.08, 0.08)
    g.setColor(1, 1, 1)
    g.print("Could not connect", W / 2 - 70, 120)
    g.print(tostring(game.error), 40, 160)
    g.print("Start the server (server/build/platformer_server) and press ENTER to retry.", 40, 200)
    g.print("ESC to quit.", 40, 240)
end

function start_connect()
    local net = Net.new({})
    game.net = net
    game.state = "connecting"
    -- Present the "connecting" frame before the blocking connect call.
    love.graphics.origin()
    love.draw()
    love.graphics.present()

    local ok, err = net:connect()
    if not ok then
        game.error = err
        game.state = "error"
        return
    end

    game.world = World.new({ net = net, char = game.char, name = game.name })
    if os.getenv("LPD_SCRIPT") == "walk" then game.world.auto_walk = true end
    local power = tonumber(os.getenv("LPD_POWER") or "")
    if power then game.world.local_player:set_power(power) end
    net:send(("~J|%s|%s|%d"):format(net.my_id_str, game.name, game.char))
    game.state = "playing"
end

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------

local function cycle_char(delta)
    game.char = ((game.char - 1 + delta) % #Config.CHARACTERS) + 1
end

function love.keypressed(key)
    if game.state == "title" then
        if key == "escape" then love.event.quit()
        elseif key == "return" or key == "kpenter" then start_connect()
        elseif key == "tab" or key == "right" or key == "d" then cycle_char(1)
        elseif key == "left" or key == "a" then cycle_char(-1)
        else
            local n = tonumber(key)
            if n and n >= 1 and n <= #Config.CHARACTERS then game.char = n end
        end
        return
    end

    if game.state == "error" then
        if key == "escape" then love.event.quit()
        elseif key == "return" then start_connect() end
        return
    end

    if game.state ~= "playing" then return end

    if game.chat_active then
        if key == "return" or key == "kpenter" then
            if #game.chat_text > 0 and game.net then game.net:send(game.chat_text) end
            game.chat_text = ""
            game.chat_active = false
            game.world.chat_active = false
        elseif key == "escape" then
            game.chat_text = ""
            game.chat_active = false
            game.world.chat_active = false
        elseif key == "backspace" then
            game.chat_text = game.chat_text:sub(1, -2)
        end
        return
    end

    if key == "t" then
        game.chat_active = true
        game.world.chat_active = true
    elseif key == "b" or key == "f" then
        game.world:shoot()
    elseif key == "escape" then
        love.event.quit()
    elseif key == "f11" then
        love.window.setFullscreen(not love.window.getFullscreen())
    end
end

function love.textinput(text)
    if game.state == "playing" and game.chat_active then
        if #game.chat_text < 120 then game.chat_text = game.chat_text .. text end
    end
end

function draw_chat_box()
    if not game.chat_active then return end
    local g = love.graphics
    local W, H = g.getWidth(), g.getHeight()
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", 8, H - 32, W - 16, 24)
    g.setColor(1, 1, 1)
    g.print("Say: " .. game.chat_text .. "_", 14, H - 28)
end

function love.quit()
    if game.net then game.net:close() end
    return false
end
