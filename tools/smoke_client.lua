-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Valtteri Viirret
--
-- Love2D Platformer Demo networking smoke test.
-- Run the server first, then:
--   NEXILISC_LIBRARY=<repo>/nexilis/build/libnexilisc.so \
--   LD_LIBRARY_PATH=<repo>/nexilis/build \
--   LUA_PATH="<repo>/nexilis/bindings/lua/?.lua;;" \
--   luajit tools/smoke_client.lua [name]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../nexilis/bindings/lua/?.lua;" .. package.path

local nexilis = require("nexilis")

local name = arg[1] or "smoke"
local seen = {}

local client = nexilis.new({
    server_address = "127.0.0.1",
    password = "password",
    authentication_mode = nexilis.AuthenticationMode.SKIP,
    auto_join = false,
    on_ready = function(_, room)
        print(("[%s] joined room %s (%s/%s)"):format(name, room.name,
            room.client_count, room.max_size))
    end,
    on_remote_client_added = function(_, id)
        print(("[%s] + player %s"):format(name, nexilis.id_string(id)))
    end,
    on_remote_client_removed = function(_, id)
        print(("[%s] - player %s"):format(name, nexilis.id_string(id)))
    end,
    on_remote_client_position = function(_, id, position)
        seen[nexilis.id_string(id)] = { position.x, position.y, position.z }
    end,
})

local ok, err = client:connect()
if not ok then
    client:close()
    error("connect failed: " .. tostring(err))
end

print(("[%s] my id is %s"):format(name, nexilis.id_string(client:client_id())))

local rooms = {}
for _ = 1, 60 do
    rooms = client:rooms()
    if #rooms > 0 then break end
    os.execute("sleep 0.1")
end
print(("[%s] %d room(s) on the server"):format(name, #rooms))
for _, room in ipairs(rooms) do
    print(("    %s  %s"):format(nexilis.id_string(room.id), room.name))
end
assert(#rooms > 0, "server has no rooms")
assert(client:join_any_room(), "failed to join a room")
print(("[%s] in room %s"):format(name, nexilis.id_string(client:room_id())))

client:broadcast(("hello from %s"):format(name))

for frame = 1, 40 do
    client:send_position(frame * 8, 64, 7)
    client:update()
    local events = client:drain_events_json()
    if events and events ~= "" and events ~= "{}" then
        local chatStart = events:find('"chat":%[')
        if chatStart then
            for sender, message in events:gmatch('"sender":"(%d+)","message":"([^"]*)"') do
                print(("[%s] chat from %s: %s"):format(name, sender, message))
            end
        end
    end
    os.execute("sleep 0.05")
end

client:broadcast(("bye from %s"):format(name))
os.execute("sleep 0.2")
client:update()
client:close()
for id, pos in pairs(seen) do
    print(("[%s] last saw %s at (%.0f, %.0f, %.0f)"):format(name, id,
        pos[1], pos[2], pos[3]))
end
print(("[%s] done"):format(name))
