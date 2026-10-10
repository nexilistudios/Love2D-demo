#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Valtteri Viirret
#
# Build the Nexilis shared libraries and the dedicated game server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jobs="${JOBS:-$(nproc)}"

echo "==> Building Nexilis libraries"
# CI=false makes CMake prefer the system Boost / OpenSSL (see nexilis/AGENTS.md).
CI=false cmake -S "$here/nexilis" -B "$here/nexilis/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$here/nexilis/build" --parallel "$jobs"

echo "==> Building the Love2D Platformer Demo server"
cmake -S "$here/server" -B "$here/server/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$here/server/build" --parallel "$jobs"

echo
echo "Done. Run the server with:  ./server/build/platformer_server"
echo "And a client with:          ./run.sh"
