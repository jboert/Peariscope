#include "CrashLog.h"

#include <signal.h>
#include <unistd.h>
#include <chrono>
#include <ctime>
#include <sstream>
#include <iostream>
#include <cstring>
#include <cstdlib>

namespace peariscope {

std::ofstream CrashLog::file_;
std::mutex CrashLog::mutex_;
bool CrashLog::initialized_ = false;

std::filesystem::path CrashLog::LogPath() {
    const char* home = getenv("HOME");
    if (!home) home = "/tmp";
    std::filesystem::path dir = std::string(home) + "/.config/peariscope";
    std::filesystem::create_directories(dir);
    return dir / "peariscope-crash.log";
}

std::string CrashLog::Timestamp() {
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;

    struct tm tmBuf;
    localtime_r(&time, &tmBuf);

    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tmBuf);

    std::ostringstream oss;
    oss << buf << "." << std::setfill('0') << std::setw(3) << ms.count();
    return oss.str();
}

const char* CrashLog::LevelStr(Level l) {
    switch (l) {
        case Level::Info:  return "INFO";
        case Level::Warn:  return "WARN";
        case Level::Error: return "ERROR";
        case Level::Fatal: return "FATAL";
    }
    return "UNKNOWN";
}

size_t CrashLog::GetMemoryMB() {
    size_t memKB = 0;
    std::ifstream status("/proc/self/status");
    if (status.is_open()) {
        std::string line;
        while (std::getline(status, line)) {
            if (line.rfind("VmRSS:", 0) == 0) {
                std::istringstream iss(line.substr(6));
                iss >> memKB;
                break;
            }
        }
    }
    return memKB / 1024;
}

// Escape a string for JSON output
static std::string JsonEscape(const std::string& s) {
    std::ostringstream oss;
    for (char c : s) {
        switch (c) {
            case '"':  oss << "\\\""; break;
            case '\\': oss << "\\\\"; break;
            case '\n': oss << "\\n"; break;
            case '\r': oss << "\\r"; break;
            case '\t': oss << "\\t"; break;
            default:   oss << c; break;
        }
    }
    return oss.str();
}

void CrashLog::Write(const std::string& jsonLine) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (file_.is_open()) {
        file_ << jsonLine << "\n";
        file_.flush();
    }
}

void CrashLog::Init() {
    if (initialized_) return;

    auto path = LogPath();
    file_.open(path, std::ios::out | std::ios::trunc);

    if (!file_.is_open()) {
        std::cerr << "CrashLog: failed to open " << path << std::endl;
        return;
    }

    // Install signal handlers
    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND; // One-shot to avoid recursive signals

    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
    sigaction(SIGBUS,  &sa, nullptr);
    sigaction(SIGFPE,  &sa, nullptr);

    initialized_ = true;

    Log(Level::Info, "CrashLog initialized");
}

void CrashLog::SignalHandler(int sig) {
    // Async-signal-safe: write directly to the file descriptor
    // We avoid the mutex here since we may be in a corrupted state
    const char* sigName = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: sigName = "SIGSEGV"; break;
        case SIGABRT: sigName = "SIGABRT"; break;
        case SIGBUS:  sigName = "SIGBUS";  break;
        case SIGFPE:  sigName = "SIGFPE";  break;
    }

    // Best-effort write to log file
    if (file_.is_open()) {
        // Build a simple crash line (avoid allocations in signal handler)
        char buf[256];
        int len = snprintf(buf, sizeof(buf),
            "{\"time\":\"CRASH\",\"level\":\"FATAL\",\"msg\":\"Signal %s (%d) received\"}\n",
            sigName, sig);
        if (len > 0 && len < static_cast<int>(sizeof(buf))) {
            // Use low-level write to be async-signal-safe
            auto fd = fileno(stderr);
            (void)write(fd, buf, len);

            // Also try writing to the log file
            file_ << buf;
            file_.flush();
        }
    }

    _exit(1);
}

void CrashLog::Log(Level level, const std::string& msg) {
    if (!initialized_) return;

    std::ostringstream oss;
    oss << "{\"time\":\"" << Timestamp()
        << "\",\"level\":\"" << LevelStr(level)
        << "\",\"mem_mb\":" << GetMemoryMB()
        << ",\"msg\":\"" << JsonEscape(msg) << "\"}";

    Write(oss.str());
}

void CrashLog::Heartbeat(double fps, size_t connectedPeers) {
    if (!initialized_) return;

    std::ostringstream oss;
    oss << "{\"time\":\"" << Timestamp()
        << "\",\"level\":\"INFO\""
        << ",\"type\":\"heartbeat\""
        << ",\"fps\":" << std::fixed << std::setprecision(1) << fps
        << ",\"peers\":" << connectedPeers
        << ",\"mem_mb\":" << GetMemoryMB() << "}";

    Write(oss.str());
}

void CrashLog::CheckPreviousCrash() {
    auto path = LogPath();
    if (!std::filesystem::exists(path)) return;

    std::ifstream file(path);
    if (!file.is_open()) return;

    bool hadFatal = false;
    std::string line;
    while (std::getline(file, line)) {
        if (line.find("\"FATAL\"") != std::string::npos) {
            hadFatal = true;
            break;
        }
    }
    file.close();

    if (hadFatal) {
        std::cerr << "[peariscope] WARNING: Previous session crashed. "
                  << "Crash log: " << path << std::endl;
    }
}

} // namespace peariscope
