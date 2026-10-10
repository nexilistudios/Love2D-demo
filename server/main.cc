/* SPDX-License-Identifier: MIT
   Copyright (C) 2026 Valtteri Viirret
   Love2D Platformer Demo: Server

   The server is a headless Nexilis room server for the multiplayer
   "Love2D Platformer Demo" LÖVE game. It:

     * Opens the Boost TCP and UDP transports next to the game clients.
     * Pre-creates the single shared "Level 1" room so every client that
       connects auto-joins the same world.
     * Relays all room commands (positions over UDP, broadcasts over TCP)
       between clients. The shared world clock is maintained by the clients
       themselves: each periodically broadcasts a compact "T" time-sync
       message and every client merges forward only, so the server stays a
       pure relay. */

#include <nexilis/logger/log.hh>
#include <nexilis/ports.hh>
#include <nexilis/protocol_manager.hh>
#include <nexilis/room_data.hh>
#include <nexilis/server/client_storage.hh>
#include <nexilis/server/command/command.hh>
#include <nexilis/server/command/command_result.hh>
#include <nexilis/server/protocol/nxboost/tcp_server.hh>
#include <nexilis/server/protocol/nxboost/udp_server.hh>
#include <nexilis/server/room.hh>
#include <nexilis/server/room_storage.hh>
#include <nexilis/server/server_config.hh>
#include <nexilis/server/user.hh>
#include <nexilis/util.hh>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

namespace
{

std::atomic<bool> g_running{true};

void handleSignal(int)
{
    g_running.store(false);
}

/// The game tick rate used for the shared world clock.
constexpr std::uint64_t kTickrate = 60;

/// The server re-checks its stop flag at this cadence.
constexpr std::chrono::milliseconds kIdleInterval{200};

void runUntilStopped()
{
    while (g_running.load())
    {
        std::this_thread::sleep_for(kIdleInterval);
    }
}

} // namespace

int main(int argc, char** argv)
{
    // The library logs every packet at Info level, which is far too chatty for
    // a game server; Warning keeps the console readable while still surfacing
    // real problems.
    nexilis::Log::startConsoleLogging(nexilis::logger::LogLevel::Warning);

    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);

    // "skip" authentication: no password needed, perfect for a LAN demo.
    // Set LPD_PASSWORD to require it instead.
    const char* password = std::getenv("LPD_PASSWORD");
    nexilis::server::ServerConfig settings;
    if (password && *password)
    {
        settings.setMode(nexilis::server::AuthenticationMode::password_protected);
        settings.setPassphrase(password);
        settings.setRootPassword(password);
    }
    else
    {
        settings.setMode(nexilis::server::AuthenticationMode::skip);
    }

    nexilis::ProtocolManager protocol_manager;
    auto tcp_server = protocol_manager.createProtocol<nexilis::server::nxboost::TCPServer>(settings);
    auto udp_server = protocol_manager.createProtocol<nexilis::server::nxboost::UDPServer>(settings);

    tcp_server.start();
    udp_server.start();

    std::cout << "Love2D Platformer Demo server listening" << std::endl;
    std::cout << "  Boost TCP  : 127.0.0.1:" << nexilis::Ports::getBoostTCPPort()
              << std::endl;
    std::cout << "  Boost UDP  : 127.0.0.1:" << udp_server.getPort() << std::endl;
    std::cout << "  auth mode  : "
              << (password && *password ? "password protected" : "skip (open)")
              << std::endl;
    std::cout << "  world clock: " << kTickrate
              << " ticks/s, synced peer-to-peer (server is a relay)" << std::endl;
    std::cout << "Press Ctrl+C to stop." << std::endl;

    // Pre-create the single shared room so clients auto-join it.
    // Context::_2D matches the side-scrolling world; the game still uses the
    // 3D position packets which the relay accepts in any context.
    const uint64_t roomId = nexilis::Util::getRandomUint64();
    const nexilis::RoomData roomData(0, "Level 1", roomId,
                                     nexilis::RoomData::Context::_2D, 12);
    nexilis::server::Room room(roomData);

    // Let rooms overlap players so co-op buddies can stand next to each other
    // without the server rejecting the same coordinates.
    room.setOverlappingAllowed(true);

    nexilis::server::RoomStorage::add(std::move(room));
    nexilis::Log::info("Opened room \"Level 1\" (id ", roomId, ")");

    runUntilStopped();

    std::cout << "Stopping server..." << std::endl;
    tcp_server.stop();
    udp_server.stop();
    std::cout << "Server stopped. Bye!" << std::endl;
    return EXIT_SUCCESS;
}
