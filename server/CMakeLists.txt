# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Valtteri Viirret

cmake_minimum_required(VERSION 3.25)
project(platformer_server LANGUAGES CXX)

add_subdirectory(../nexilis/nexilis nexilis_dir)
add_executable(platformer_server main.cc)
target_link_libraries(platformer_server nexilis)