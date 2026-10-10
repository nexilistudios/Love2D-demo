# Working on Love2D Platformer Demo

This is a multiplayer Super Mario–style platformer: a LÖVE (Lua) client in
`game/` and a headless C++ relay server in `server/`, talking over the
[Nexilis](nexilis) library. This file is the entry point for
anyone (human or agent) changing the game; read it before editing.

The `nexilis/` directory is a git submodule with **its own `AGENTS.md`**. Read
and follow that file before touching anything under `nexilis/`; it is not part
of the game and should rarely need changes.

## Repository map

| Path | Purpose |
| --- | --- |
| `game/main.lua` | LÖVE entry point: title/connecting/playing/error state machine, input, chat, test hooks. |
| `game/world.lua` | Simulation loop, input latch, camera, HUD, chat, event handling, session/clock logic. |
| `game/level.lua` | Level 1 tile map, enemy/coin spawns, tile/decoration drawing. |
| `game/player.lua` | Player physics, remote interpolation, state (de)packing for the wire. |
| `game/entities.lua` | Enemies, items, fireballs, block bumps, collisions, network event application. |
| `game/sprites.lua` | Procedurally generated pixel-art sprites and palettes. |
| `game/net.lua` | Nexilis client wrapper, text protocol parser, world-clock sync. |
| `game/config.lua` | All tunables: physics, tile size, scale, characters, palette. |
| `game/conf.lua` | LÖVE window/config. |
| `game/json.lua` | Tiny JSON decoder for the binding's event payloads. |
| `game/nexilis.lua` | **Generated**: a copy of `nexilis/bindings/lua/nexilis.lua`, placed by `run.sh`. Do not edit. |
| `server/main.cc` | Headless Nexilis server: opens transports, pre-creates the room, relays. No game logic. |
| `server/CMakeLists.txt` | Builds `platformer_server`, linking the `nexilis` submodule. |
| `tools/smoke_client.lua` | Standalone LuaJIT client used to probe the binding by hand. |
| `build.sh` / `run.sh` | Build the native libs + server, and launch the LÖVE client. |
| `docs/` | Screenshots used by `README.md`. |
| `LICENSE` | MIT license for the project (the Nexilis submodule stays LGPL). |
| `.gitignore` | Ignores build output and the generated `game/nexilis.lua`. |

## Build and dependencies

Native builds need CMake 3.25+, a C++20 compiler, OpenSSL and Boost development
files. LÖVE 11.x and LuaJIT (for `tools/`) must be on `PATH`.

```sh
# One-time, if the submodule is empty:
git submodule update --init --recursive

# Build the Nexilis shared libraries and the dedicated server:
./build.sh
```

`build.sh` runs CMake with `CI=false`, which makes it prefer the **system**
Boost/OpenSSL instead of the vendored submodule (see `nexilis/AGENTS.md`). If it
picks the wrong dependencies, that variable is the first thing to check. Reuse
`nexilis/build` and `server/build` between edits; they do not need rebuilding
for Lua-only changes.

The game itself is plain Lua and needs no build step.

## Run

Start the server once, then launch one client per player (see the README for the
full user-facing guide):

```sh
# Terminal 1: dedicated server (TCP 54200, UDP ephemeral).
./server/build/platformer_server

# Terminal 2..n: one client per player.
./run.sh
```

`run.sh` copies the LuaJIT binding next to the game (LÖVE loads modules from its
own source directory, so `require("nexilis")` needs `game/nexilis.lua`), exports
`NEXILISC_LIBRARY`/`LD_LIBRARY_PATH`, and runs `love game`.

Client environment variables:

| Variable | Meaning |
| --- | --- |
| `NX_HOST` | Server address (default `127.0.0.1`). |
| `NX_PASSWORD` | Server password, if the server requires one. |
| `LPD_NAME` | Player name; random `PlayerNNNN` if unset. |
| `LPD_AUTOSTART` | Skip the title screen and connect immediately. |
| `LPD_TEST_SECONDS` | Quit after N seconds and print a summary (test hook). |
| `LPD_SCRIPT` | `walk` enables a scripted auto-walk test driver. |
| `LPD_CHAR` | Starting character index (title screen selection otherwise). |
| `LPD_POWER` | Starting power state (0 small, 1 big, 2 fire). |
| `LPD_DEBUG` | `1` prints a periodic player-state line. |
| `LPD_SCREENSHOT` | Filename to write a PNG screenshot to on exit (test hook). |

The server is skip-auth by default; set `LPD_PASSWORD` to require a password.

## How it works

- **Fixed-step simulation.** The world runs at 60 Hz (`Config.TICKRATE`); input
  is latched on the render frame and consumed inside `World:step_tick`.
- **Shared clock.** Every client broadcasts `T|<tick>` about once a second and
  merges **forward only** (highest tick wins, never backward), so a late joiner
  is pulled forward and a leaver cannot drag the clock back. The server is a
  pure relay and runs no game logic.
- **Player state** goes over UDP (`send_position`) roughly 30×/s as `x`, `y` and
  a packed `z` (character, power, facing, action, alive, star).
- **Events** go over the reliable TCP chat channel as `~`-prefixed text; the
  server stores them and replays them to joiners.
- **Enemies are deterministic**: their position is a pure function of the shared
  `worldTick` and the level geometry, so only *state changes* are broadcast,
  tagged with the tick they happened on. Items are simulated forward from their
  `spawnTick`.
- **Fireballs** are authoritative only for the client that fired them; everyone
  else applies the resulting `~E` hit. This keeps kills identical despite
  slightly different spawn timing.
- **Sessions.** A client that finds the room empty starts a new session
  (`~S|<epoch>`) and rebuilds Level 1; joiners replay history in order and
  converge on the newest session, so stale kills/broken bricks never leak
  between games.

### Wire protocol

Successor to chat: any message starting with `~` is a protocol event, `T|` is a
clock tick, anything starting with `> ` is server/system noise (ignored), and
everything else is chat.

| Message | Fields |
| --- | --- |
| `~S` | `epoch` — new session marker |
| `~J` | `pid`, `name`, `char` — join (name/char only; presence is authoritative) |
| `~B` | `tx`, `ty`, `pid`, `tick` — block bump |
| `~X` | `tx`, `ty`, `pid` — brick break |
| `~O` | `tx`, `ty`, `pid` — coin collected |
| `~I` | `tx`, `ty`, `pid` — item collected |
| `~E` | `idx`, `pid`, `mode` (squish/shell/flip), `x`, `tick`, `vx` — enemy state change |
| `~K` | `idx`, `pid`, `dir`, `x`, `tick` — shell kick |
| `~F` | `pid`, `x`, `y`, `dir`, `tick` — fireball spawn |
| `~D` | `pid` — death |
| `~G` | `pid`, `points` — reached the goal |
| `T` | `tick` — clock heartbeat (no `~`) |

Keep the parser (`net.lua`), the router (`world.lua` `handle_event`) and the
emitters (`entities.lua`, `world.lua`) in agreement when you add a field or a
new message.

## Testing

The game is validated headlessly. Run the client under `xvfb-run` with software
GL and a dummy audio driver, using the test hooks above:

```sh
LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy \
  LPD_AUTOSTART=1 LPD_SCRIPT=walk LPD_TEST_SECONDS=15 \
  xvfb-run -a ./run.sh
```

On exit it prints a summary (packed `z`, every player's position/power/score,
enemy/item/fireball counts, steps/s). Multiplayer is checked by running several
clients concurrently and confirming they agree — e.g. identical
`walk/shell/slide/gone` enemy counts. Screenshots (with `LPD_SCREENSHOT`) land
in LÖVE's save directory (`~/.local/share/love/love2d-platformer-demo/`).

`tools/smoke_client.lua` exercises the raw binding without LÖVE; point
`NEXILISC_LIBRARY`, `LD_LIBRARY_PATH` and `LUA_PATH` at `nexilis/build` and
`nexilis/bindings/lua`.

There is no automated test runner in this repository; at minimum, syntax-check
Lua with `luajit -e "assert(loadfile('game/foo.lua'))"` and run a headless
multiplayer session for behavioral changes.

## Editing conventions

- Match the surrounding Lua style; keep `game/` free of build steps.
- **Never edit `game/nexilis.lua`** — it is copied from the submodule by
  `run.sh`. Change `nexilis/bindings/lua/nexilis.lua` instead, and mind
  `nexilis/AGENTS.md`.
- The C++ server is intentionally a **pure relay**. Do not add game logic or
  background threads that touch room internals: Nexilis runs one command thread
  per client and its shared room vectors (`m_clientIds`, `m_broadcasts`) are not
  synchronized, so concurrent access from another thread races and can corrupt
  the heap. This is why the clock lives on the clients.
- Run `clang-format` on changed C++ files.
- Keep the server logging at `Warning`; the library logs every packet at `Info`.
- Update `README.md` and this file when behavior or the protocol changes.

## Licensing

- The game code (everything in `game/` except the generated `game/nexilis.lua`,
  plus `server/`, `tools/`, the shell scripts and this documentation) is
  **MIT-licensed**; see `LICENSE`. Copyright (c) 2026 Valtteri Viirret.
- `nexilis/` is a separate git submodule under **LGPL-3.0-or-later**; see
  `nexilis/LICENSE` and `nexilis/AGENTS.md`. `game/nexilis.lua` is a generated
  copy of its LuaJIT binding and inherits that license.
- Keep the SPDX header (`SPDX-License-Identifier: MIT`) at the top of new game
  source files, and do not strip the existing headers.
- Super Mario Bros. is a Nintendo trademark; keep the "unaffiliated homage"
  framing in user-facing docs.
