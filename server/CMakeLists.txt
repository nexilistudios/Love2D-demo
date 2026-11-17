# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Valtteri Viirret

cmake_minimum_required(VERSION 3.25)
project(platformer_server LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prefer the Nexilis build produced by ../build.sh (reuses system deps and avoids
# rebuilding vendored Boost submodules). Fall back to building from source.
find_package(Nexilis QUIET PATHS "${CMAKE_CURRENT_LIST_DIR}/../nexilis/build" NO_DEFAULT_PATH)
if(NOT Nexilis_FOUND)
    add_subdirectory(../nexilis/nexilis nexilis_dir)
endif()

add_executable(platformer_server main.cc)
if(TARGET Nexilis::nexilis)
    target_link_libraries(platformer_server PRIVATE Nexilis::nexilis)
else()
    target_link_libraries(platformer_server PRIVATE nexilis)
endif()