#pragma once

#include <string>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <cstdint>

namespace peariscope {

class CrashLog {
public:
    enum class Level { Info, Warn, Error, Fatal };

    static void Init();
    static void Log(Level level, const std::string& msg);
    static void Heartbeat(double fps, size_t connectedPeers);
    static void CheckPreviousCrash();
    static std::filesystem::path LogPath();

private:
    static void Write(const std::string& jsonLine);
    static const char* LevelStr(Level l);
    static size_t GetMemoryMB();
    static std::string Timestamp();
    static void SignalHandler(int sig);

    static std::ofstream file_;
    static std::mutex mutex_;
    static bool initialized_;
};

} // namespace peariscope
