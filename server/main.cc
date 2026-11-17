/* SPDX-License-Identifier: MIT
   Copyright (C) 2026 Valtteri Viirret
   Love2D Platformer Demo: Server

   The server is a headless Nexilis room server for the multiplayer
   "Love2D Platformer Demo" LÖVE game. It:

     * Opens the Boost TCP and UDP transports next to the game clients, with
       a persistent TLS identity for Boost TCP's certificate pinning.
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
#include <nexilis/tls.hh>
#include <nexilis/util.hh>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>

namespace
{

std::atomic<bool> g_running{true};

void handleSignal(int)
{
    g_running.store(false);
}

std::filesystem::path tlsDirectory(const char* argv0)
{
    if (const char* configured = std::getenv("LPD_TLS_DIR"))
        return std::filesystem::path(configured);

    std::filesystem::path executableDir = std::filesystem::path(argv0).parent_path();
    if (executableDir.empty())
        executableDir = ".";
    // The server normally lives in server/build, next to server/tls.
    return (executableDir / ".." / "tls").lexically_normal();
}

std::string readFile(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
        return {};
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

bool writeFile(const std::filesystem::path& path, const std::string& contents,
               bool privateFile = false)
{
    std::error_code error;
    std::filesystem::create_directories(path.parent_path(), error);
    if (error)
        return false;
    {
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        if (!output)
            return false;
        output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
        if (!output)
            return false;
    }
    if (privateFile)
    {
        using Permissions = std::filesystem::perms;
        std::filesystem::permissions(path, Permissions::owner_read | Permissions::owner_write,
                                     std::filesystem::perm_options::replace, error);
        if (error)
            return false;
    }
    return true;
}

struct TlsIdentityFiles
{
    std::string certificate;
    std::string privateKey;
    std::string pin;
};

/// Load the server's TLS identity, generating a persistent self-signed one on
/// first use. Clients read the pin from server.pin unless NX_SERVER_PIN is set.
bool loadTlsIdentity(int argc, char** argv, TlsIdentityFiles& result)
{
    const char* certificateEnv = std::getenv("LPD_TLS_CERT");
    const char* keyEnv = std::getenv("LPD_TLS_KEY");
    if (bool(certificateEnv) != bool(keyEnv))
    {
        std::cerr << "Set both LPD_TLS_CERT and LPD_TLS_KEY, or neither" << std::endl;
        return false;
    }

    const auto directory = tlsDirectory(argc > 0 ? argv[0] : "");
    const auto certificatePath = certificateEnv ? std::filesystem::path(certificateEnv)
                                                : directory / "cert.pem";
    const auto keyPath = keyEnv ? std::filesystem::path(keyEnv) : directory / "key.pem";

    if (!certificateEnv &&
        (!std::filesystem::exists(certificatePath) || !std::filesystem::exists(keyPath)))
    {
        const auto identity = nexilis::tls::generateSelfSignedIdentity();
        if (identity.publicKeySha256.empty())
        {
            std::cerr << "Failed to generate a TLS identity" << std::endl;
            return false;
        }
        if (!writeFile(certificatePath, identity.certificatePem) ||
            !writeFile(keyPath, identity.privateKeyPem, true))
        {
            std::cerr << "Failed to save the TLS identity in " << directory << std::endl;
            return false;
        }
        std::cout << "Generated a TLS identity in " << directory << std::endl;
    }

    result.certificate = readFile(certificatePath);
    result.privateKey = readFile(keyPath);
    if (result.certificate.empty() || result.privateKey.empty())
    {
        std::cerr << "Failed to read the TLS certificate or private key" << std::endl;
        return false;
    }

    result.pin = nexilis::tls::publicKeySha256(result.certificate);
    if (result.pin.empty() ||
        !nexilis::tls::createServerContext(result.certificate, result.privateKey))
    {
        std::cerr << "The TLS certificate or private key is invalid" << std::endl;
        return false;
    }

    const char* pinFileEnv = std::getenv("LPD_TLS_PIN_FILE");
    const auto pinPath = pinFileEnv ? std::filesystem::path(pinFileEnv) : directory / "server.pin";
    if (writeFile(pinPath, result.pin + "\n"))
    {
        std::cout << "  TLS pin file: " << pinPath << std::endl;
    }
    else
    {
        std::cerr << "Warning: could not write " << pinPath
                  << "; set NX_SERVER_PIN=" << result.pin << " on clients" << std::endl;
    }
    return true;
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
    // This demo relays frequent position/events over chat; avoid tight gameplay
    // rate limits rejecting legitimate traffic.
    settings.setMaxCommandRate(0.0f);
    settings.getGameplayLimits().setMaxBroadcastRate(0.0f);
    if (password && *password)
    {
        settings.setMode(nexilis::server::AuthenticationMode::password_protected);
        settings.setPassphrase(password);
        settings.setRootPassword(password);
        settings.setTls(true);
    }
    else
    {
        // Skip auth for the LAN demo. TLS still needs a server identity; the
        // passphrase is kept for the optional password-protected mode.
        settings.setMode(nexilis::server::AuthenticationMode::skip);
        settings.setPassphrase("platformer-demo");
        settings.setTls(true);
    }

    TlsIdentityFiles tlsIdentity;
    if (!loadTlsIdentity(argc, argv, tlsIdentity))
        return EXIT_FAILURE;
    settings.setTlsIdentity(tlsIdentity.certificate, tlsIdentity.privateKey);

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
    std::cout << "  TLS pin    : " << tlsIdentity.pin << std::endl;
    std::cout << "  world clock: " << kTickrate
              << " ticks/s, synced peer-to-peer (server is a relay)" << std::endl;
    std::cout << "Press Ctrl+C to stop." << std::endl;

    // Pre-create the single shared room so clients auto-join it.
    // The game uses 3D position packets (z carries packed player state), so the
    // room uses 3D context even though gameplay is a 2D side-scroller.
    const uint64_t roomId = nexilis::Util::getRandomUint64();
    const nexilis::RoomData roomData(0, "Level 1", roomId,
                                     nexilis::RoomData::Context::_3D, 12);
    nexilis::server::Room room(roomData);

    // Let rooms overlap players so co-op buddies can stand next to each other
    // without the server rejecting the same coordinates.
    room.setOverlappingAllowed(true);
    // This demo relays client-authored player positions over UDP.
    room.setClientPositionAllowed(true);

    nexilis::server::RoomStorage::add(std::move(room));
    nexilis::Log::info("Opened room \"Level 1\" (id ", roomId, ")");

    runUntilStopped();

    std::cout << "Stopping server..." << std::endl;
    tcp_server.stop();
    udp_server.stop();
    std::cout << "Server stopped. Bye!" << std::endl;
    return EXIT_SUCCESS;
}
