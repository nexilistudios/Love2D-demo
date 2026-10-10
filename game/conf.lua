-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- LÖVE configuration for Love2D Platformer Demo

function love.conf(t)
    t.identity = "love2d-platformer-demo"
    t.version = "11.5"
    t.console = false

    t.window.title = "Love2D Platformer Demo"
    t.window.width = 1280
    t.window.height = 720
    t.window.resizable = true
    t.window.minwidth = 640
    t.window.minheight = 360
    t.window.vsync = 1

    t.modules.joystick = false
    t.modules.physics = false
end
