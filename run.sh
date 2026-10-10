#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Valtteri Viirret
#
# Launch Love2D Platformer Demo as a LÖVE client.
#
# Environment variables:
#   NX_HOST         server address (default 127.0.0.1)
#   NX_PASSWORD     password, if the server is password protected
#   LPD_NAME      player name shown to other players
#   LPD_AUTOSTART skip the title screen and connect immediately (testing)
#   LPD_TEST_SECONDS  quit after N seconds (testing)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$here/nexilis/build"

if [[ ! -f "$build_dir/libnexilisc.so" ]]; then
    echo "nexilisc is not built yet; run ./build.sh first" >&2
    exit 1
fi

# LÖVE loads modules from its own source directory, so the LuaJIT binding has
# to live next to the game files.
cp -f "$here/nexilis/bindings/lua/nexilis.lua" "$here/game/nexilis.lua"

export NEXILISC_LIBRARY="${NEXILISC_LIBRARY:-$build_dir/libnexilisc.so}"
export LD_LIBRARY_PATH="$build_dir:${LD_LIBRARY_PATH:-}"

exec love "$here/game" "$@"
