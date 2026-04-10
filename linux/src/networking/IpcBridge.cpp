#include "IpcBridge.h"

#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>

#include <unistd.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <time.h>
#include <fcntl.h>

// Minimal JSON helpers -- we only need to produce small objects and parse small
// objects coming back from the worklet. A full JSON library (nlohmann, rapidjson)
// can replace these trivially if one is already in the project.
namespace {

// --------------------------------------------------------------------------
// Tiny JSON builder (produces {"key":"value", ...})
// --------------------------------------------------------------------------
std::string JsonObject(
    const std::vector<std::pair<std::string, std::string>>& kvs)
{
    std::ostringstream os;
    os << '{';
    for (size_t i = 0; i < kvs.size(); ++i) {
        if (i) os << ',';
        os << '"' << kvs[i].first << "\":\"" << kvs[i].second << '"';
    }
    os << '}';
    return os.str();
}

// --------------------------------------------------------------------------
// Tiny JSON reader helpers (no dependencies)
// --------------------------------------------------------------------------

/// Skip whitespace starting at pos; return new pos.
size_t SkipWs(const std::string& s, size_t pos) {
    while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\t' ||
                               s[pos] == '\r' || s[pos] == '\n'))
        ++pos;
    return pos;
}

/// Read a JSON string starting at pos (which should point at the opening '"').
/// Returns the unescaped string and advances pos past the closing '"'.
std::string ReadJsonString(const std::string& s, size_t& pos) {
    if (pos >= s.size() || s[pos] != '"') return {};
    ++pos; // skip opening "
    std::string out;
    while (pos < s.size() && s[pos] != '"') {
        if (s[pos] == '\\' && pos + 1 < s.size()) {
            ++pos;
            switch (s[pos]) {
            case '"':  out += '"'; break;
            case '\\': out += '\\'; break;
            case '/':  out += '/'; break;
            case 'n':  out += '\n'; break;
            case 'r':  out += '\r'; break;
            case 't':  out += '\t'; break;
            default:   out += s[pos]; break;
            }
        } else {
            out += s[pos];
        }
        ++pos;
    }
    if (pos < s.size()) ++pos; // skip closing "
    return out;
}

/// Read a JSON number (integer) starting at pos.  Advances pos.
int64_t ReadJsonInt(const std::string& s, size_t& pos) {
    size_t start = pos;
    if (pos < s.size() && s[pos] == '-') ++pos;
    while (pos < s.size() && s[pos] >= '0' && s[pos] <= '9') ++pos;
    return std::stoll(s.substr(start, pos - start));
}

/// Read a JSON boolean starting at pos.  Advances pos.
bool ReadJsonBool(const std::string& s, size_t& pos) {
    if (s.compare(pos, 4, "true") == 0) { pos += 4; return true; }
    if (s.compare(pos, 5, "false") == 0) { pos += 5; return false; }
    return false;
}

/// Skip a JSON value (string, number, object, array, bool, null).
void SkipJsonValue(const std::string& s, size_t& pos) {
    pos = SkipWs(s, pos);
    if (pos >= s.size()) return;
    if (s[pos] == '"') { ReadJsonString(s, pos); return; }
    if (s[pos] == '{') {
        int depth = 1; ++pos;
        while (pos < s.size() && depth > 0) {
            if (s[pos] == '{') ++depth;
            else if (s[pos] == '}') --depth;
            else if (s[pos] == '"') { ReadJsonString(s, pos); continue; }
            ++pos;
        }
        return;
    }
    if (s[pos] == '[') {
        int depth = 1; ++pos;
        while (pos < s.size() && depth > 0) {
            if (s[pos] == '[') ++depth;
            else if (s[pos] == ']') --depth;
            else if (s[pos] == '"') { ReadJsonString(s, pos); continue; }
            ++pos;
        }
        return;
    }
    // number / bool / null
    while (pos < s.size() && s[pos] != ',' && s[pos] != '}' && s[pos] != ']')
        ++pos;
}

/// Parse a flat JSON object into string->string map.
/// Numeric / bool values are stored as their textual representation.
std::unordered_map<std::string, std::string> ParseJsonFlat(const std::string& s) {
    std::unordered_map<std::string, std::string> out;
    size_t pos = SkipWs(s, 0);
    if (pos >= s.size() || s[pos] != '{') return out;
    ++pos;

    while (true) {
        pos = SkipWs(s, pos);
        if (pos >= s.size() || s[pos] == '}') break;

        std::string key = ReadJsonString(s, pos);
        pos = SkipWs(s, pos);
        if (pos < s.size() && s[pos] == ':') ++pos;
        pos = SkipWs(s, pos);

        if (pos >= s.size()) break;

        if (s[pos] == '"') {
            out[key] = ReadJsonString(s, pos);
        } else if (s[pos] == 't' || s[pos] == 'f') {
            bool v = ReadJsonBool(s, pos);
            out[key] = v ? "true" : "false";
        } else if (s[pos] == 'n') {
            pos += 4; // null
            out[key] = "null";
        } else if (s[pos] == '{' || s[pos] == '[') {
            size_t start = pos;
            SkipJsonValue(s, pos);
            out[key] = s.substr(start, pos - start);
        } else {
            // number
            size_t start = pos;
            int64_t v = ReadJsonInt(s, pos);
            (void)v;
            out[key] = s.substr(start, pos - start);
        }

        pos = SkipWs(s, pos);
        if (pos < s.size() && s[pos] == ',') ++pos;
    }
    return out;
}

std::string GetStr(const std::unordered_map<std::string, std::string>& m,
                   const std::string& key) {
    auto it = m.find(key);
    return it != m.end() ? it->second : std::string{};
}

int64_t GetInt(const std::unordered_map<std::string, std::string>& m,
               const std::string& key) {
    auto it = m.find(key);
    if (it == m.end() || it->second.empty()) return 0;
    try { return std::stoll(it->second); } catch (...) { return 0; }
}

bool GetBool(const std::unordered_map<std::string, std::string>& m,
             const std::string& key) {
    return GetStr(m, key) == "true";
}

// --------------------------------------------------------------------------
// Big-endian helpers
// --------------------------------------------------------------------------

inline uint32_t ReadU32BE(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8)  |  uint32_t(p[3]);
}

inline uint16_t ReadU16BE(const uint8_t* p) {
    return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}

inline void WriteU32BE(uint8_t* p, uint32_t v) {
    p[0] = uint8_t(v >> 24);
    p[1] = uint8_t(v >> 16);
    p[2] = uint8_t(v >> 8);
    p[3] = uint8_t(v);
}

inline void WriteU16BE(uint8_t* p, uint16_t v) {
    p[0] = uint8_t(v >> 8);
    p[1] = uint8_t(v);
}

// --------------------------------------------------------------------------
// Monotonic clock helper (replaces GetTickCount64)
// --------------------------------------------------------------------------

uint64_t MonotonicMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000 +
           static_cast<uint64_t>(ts.tv_nsec) / 1000000;
}

} // anonymous namespace

namespace peariscope {

// ==========================================================================
// Construction / destruction
// ==========================================================================

// Resolve the Node.js runtime path.
// Prefer a bundled "peariscope-net" next to the main executable so that
// firewall/AppArmor rules treat it as our own app rather than inheriting
// whatever state the system node binary has.
static std::string ResolveNodePath(const std::string& hint) {
    if (hint != "node") return hint;  // caller supplied explicit path

    // 1. Check for bundled runtime next to our executable.
    char exePath[4096]{};
    ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
    if (len > 0) {
        exePath[len] = '\0';
        auto bundled = std::filesystem::path(exePath).parent_path() / "peariscope-net";
        if (std::filesystem::exists(bundled)) {
            return bundled.string();
        }
    }

    // 2. Check common install locations on Linux.
    const char* candidates[] = {
        "/usr/bin/node",
        "/usr/local/bin/node",
    };
    for (auto* c : candidates) {
        if (std::filesystem::exists(c)) return c;
    }

    return hint;  // fallback to "node" and let exec fail
}

IpcBridge::IpcBridge(const std::string& nodePath,
                     const std::string& workletPath)
    : nodePath_(ResolveNodePath(nodePath))
    , workletPath_(workletPath.empty() ? ResolveWorkletPath() : workletPath)
{}

IpcBridge::~IpcBridge() {
    Stop();
}

// ==========================================================================
// Worklet path resolution
// ==========================================================================

std::string IpcBridge::ResolveWorkletPath() {
    // Resolve worklet.js by walking up from the executable directory.
    char exePath[4096]{};
    ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
    std::filesystem::path dir;
    if (len > 0) {
        exePath[len] = '\0';
        dir = std::filesystem::path(exePath).parent_path();
    } else {
        dir = std::filesystem::current_path();
    }

    // Walk up directory tree looking for pear/worklet.js
    std::filesystem::path walkDir = dir;
    for (int i = 0; i < 8; ++i) {
        auto candidate = walkDir / "pear" / "worklet.js";
        if (std::filesystem::exists(candidate)) {
            return candidate.string();
        }
        auto parent = walkDir.parent_path();
        if (parent == walkDir) break;  // reached root
        walkDir = parent;
    }

    // Fallback: next to exe
    return (dir / "pear" / "worklet.js").string();
}

// ==========================================================================
// Pear runtime path resolution
// ==========================================================================

std::string IpcBridge::ResolvePearPath() {
    // Check common locations for the pear CLI
    const char* home = std::getenv("HOME");

    if (home && home[0] != '\0') {
        // Check Pear runtime's own bin first (installed by pear CLI)
        auto pearBin = std::filesystem::path(home) / ".config" / "pear" / "bin" / "pear";
        if (std::filesystem::exists(pearBin)) return pearBin.string();

        auto localBin = std::filesystem::path(home) / ".local" / "bin" / "pear";
        if (std::filesystem::exists(localBin)) return localBin.string();
    }

    // Check alongside the executable (AppImage / portable bundle)
    auto exeDir = std::filesystem::read_symlink("/proc/self/exe").parent_path();
    auto exePear = exeDir / "pear-runtime";
    if (std::filesystem::exists(exePear)) return exePear.string();

    const char* candidates[] = {
        "/usr/local/bin/pear",
        "/usr/bin/pear",
    };
    for (auto* c : candidates) {
        if (std::filesystem::exists(c)) return c;
    }

    // Search PATH
    const char* pathEnv = std::getenv("PATH");
    if (pathEnv) {
        std::string pathStr(pathEnv);
        std::istringstream ss(pathStr);
        std::string dir;
        while (std::getline(ss, dir, ':')) {
            auto candidate = std::filesystem::path(dir) / "pear-runtime";
            if (std::filesystem::exists(candidate)) return candidate.string();
            candidate = std::filesystem::path(dir) / "pear";
            if (std::filesystem::exists(candidate) && !std::filesystem::is_directory(candidate))
                return candidate.string();
        }
    }

    return {};
}

// ==========================================================================
// Helper: get read/write fds based on mode
// ==========================================================================

int IpcBridge::ReadFd() const {
    if (launchMode_ != WorkletLaunchMode::Node && childIpcFd_ != -1) {
        return childIpcFd_;
    }
    return childStdoutFd_;
}

int IpcBridge::WriteFd() const {
    if (launchMode_ != WorkletLaunchMode::Node && childIpcFd_ != -1) {
        return childIpcFd_;
    }
    return childStdinFd_;
}

// ==========================================================================
// Subprocess lifecycle
// ==========================================================================

bool IpcBridge::Start() {
    if (running_.load(std::memory_order_acquire)) return true;

    // Auto-detect launch mode — prefer Pear runtime
    if (launchMode_ == WorkletLaunchMode::Node) {
        std::string pearPath = ResolvePearPath();
        if (!pearPath.empty()) {
            if (pearKey_.empty()) {
                launchMode_ = WorkletLaunchMode::PearDev;
            } else {
                launchMode_ = WorkletLaunchMode::PearProd;
            }
            std::cerr << "[ipc] Pear runtime found at: " << pearPath
                      << ", mode=" << (launchMode_ == WorkletLaunchMode::PearDev ? "dev" : "prod")
                      << std::endl;
        }
    }

    if (!LaunchProcess()) {
        // If Pear mode failed, fall back to Node
        if (launchMode_ != WorkletLaunchMode::Node) {
            std::cerr << "[ipc] Pear launch failed, falling back to Node" << std::endl;
            launchMode_ = WorkletLaunchMode::Node;
            if (!LaunchProcess()) return false;
        } else {
            return false;
        }
    }

    // Verify child is still alive after a brief delay (catches immediate exec failures)
    usleep(200000); // 200ms
    if (childPid_ > 0) {
        int status;
        pid_t result = waitpid(childPid_, &status, WNOHANG);
        if (result > 0) {
            // Child already exited
            std::cerr << "[ipc] Child process exited immediately (status="
                      << WEXITSTATUS(status) << ")" << std::endl;
            // Clean up fds
            if (childIpcFd_ != -1) { close(childIpcFd_); childIpcFd_ = -1; }
            if (childStdinFd_ != -1) { close(childStdinFd_); childStdinFd_ = -1; }
            if (childStdoutFd_ != -1) { close(childStdoutFd_); childStdoutFd_ = -1; }
            if (stderrFd_ != -1) { close(stderrFd_); stderrFd_ = -1; }
            childPid_ = -1;

            // Join stderr thread if it was started
            if (stderrThread_.joinable()) stderrThread_.join();

            // If was Pear mode, fall back to Node
            if (launchMode_ != WorkletLaunchMode::Node) {
                std::cerr << "[ipc] Pear child died, falling back to Node" << std::endl;
                launchMode_ = WorkletLaunchMode::Node;
                if (!LaunchProcess()) return false;
            } else {
                return false;
            }
        }
    }

    running_.store(true, std::memory_order_release);
    stopping_.store(false, std::memory_order_release);

    readThread_ = std::thread(&IpcBridge::ReadLoop, this);
    writeThread_ = std::thread(&IpcBridge::WriteLoop, this);

    return true;
}

void IpcBridge::Stop() {
    if (!running_.load(std::memory_order_acquire)) return;

    stopping_.store(true, std::memory_order_release);
    running_.store(false, std::memory_order_release);
    writeCv_.notify_all();

    TerminateProcess();

    if (readThread_.joinable()) {
        readThread_.join();
    }
    if (writeThread_.joinable()) {
        writeThread_.join();
    }
    if (stderrThread_.joinable()) {
        stderrThread_.join();
    }

    // Clear buffers
    {
        std::lock_guard<std::mutex> lk(writeMutex_);
        pendingWrite_.clear();
    }
    recvBuf_.clear();
    recvBufOffset_ = 0;
    chunkBuffers_.clear();
}

bool IpcBridge::LaunchProcess() {
    bool usePear = (launchMode_ != WorkletLaunchMode::Node);

    // Kill any orphaned pear run processes from previous sessions.
    // Zombies announce on the same DHT topic and steal connections from us.
    if (usePear) {
        std::string killCmd = "pkill -9 -f 'pear run.*" +
            std::filesystem::path(workletPath_).parent_path().string() + "' 2>/dev/null";
        system(killCmd.c_str());
        usleep(500000); // 500ms for processes to die
    }

    if (usePear) {
        // --- Pear mode: Unix domain socket for IPC ---
        // fd inheritance doesn't work through pear run's process layers,
        // so we create a UDS that the worklet connects to by path.

        // Create UDS path
        ipcSocketPath_ = "/tmp/peariscope-ipc-" + std::to_string(getpid()) + ".sock";
        unlink(ipcSocketPath_.c_str()); // remove stale socket

        int listenSock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listenSock < 0) {
            std::cerr << "[ipc] socket(AF_UNIX) failed: " << strerror(errno) << std::endl;
            return false;
        }

        struct sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, ipcSocketPath_.c_str(), sizeof(addr.sun_path) - 1);

        if (bind(listenSock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
            std::cerr << "[ipc] bind() failed: " << strerror(errno) << std::endl;
            close(listenSock);
            return false;
        }

        if (listen(listenSock, 1) != 0) {
            std::cerr << "[ipc] listen() failed: " << strerror(errno) << std::endl;
            close(listenSock);
            unlink(ipcSocketPath_.c_str());
            return false;
        }

        listenFd_ = listenSock;

        // Write socket path to well-known file so worklet can find it
        {
            std::string homeDir = getenv("HOME") ? getenv("HOME") : "/tmp";
            std::string ipcSockFile = homeDir + "/.peariscope/ipc-sock";
            std::ofstream ofs(ipcSockFile, std::ios::trunc);
            if (ofs.good()) {
                ofs << ipcSocketPath_;
                ofs.close();
                std::cerr << "[ipc] Wrote socket path to " << ipcSockFile << std::endl;
            } else {
                std::cerr << "[ipc] WARNING: Could not write " << ipcSockFile << std::endl;
            }
        }

        // Create a pipe to capture stderr from child
        int stderrPipe[2];
        if (pipe(stderrPipe) != 0) {
            std::cerr << "[ipc] pipe(stderr) failed: " << strerror(errno) << std::endl;
            close(listenSock);
            unlink(ipcSocketPath_.c_str());
            return false;
        }

        childPid_ = fork();
        if (childPid_ < 0) {
            std::cerr << "[ipc] fork() failed: " << strerror(errno) << std::endl;
            close(listenSock);
            unlink(ipcSocketPath_.c_str());
            close(stderrPipe[0]); close(stderrPipe[1]);
            return false;
        }

        if (childPid_ == 0) {
            // Child process — create new process group so we can kill the whole tree
            setpgid(0, 0);

            close(listenSock);          // parent accepts connections
            close(stderrPipe[0]);       // parent reads stderr

            // Redirect stderr to pipe for log capture
            dup2(stderrPipe[1], STDERR_FILENO);
            close(stderrPipe[1]);

            // Keep stdout -> stderr so console.log works
            dup2(STDERR_FILENO, STDOUT_FILENO);

            std::string pearPath = ResolvePearPath();
            if (pearPath.empty()) {
                std::cerr << "[ipc] Pear not found, cannot launch" << std::endl;
                _exit(1);
            }

            if (launchMode_ == WorkletLaunchMode::PearDev) {
                // Resolve pear directory (parent of worklet.js)
                std::filesystem::path pearDir = std::filesystem::path(workletPath_).parent_path();
                execlp(pearPath.c_str(), pearPath.c_str(), "run", "--dev",
                       pearDir.c_str(), nullptr);
            } else {
                // PearProd: pear run pear://<key>
                std::string pearUri = "pear://" + pearKey_;
                execlp(pearPath.c_str(), pearPath.c_str(), "run",
                       pearUri.c_str(), nullptr);
            }
            _exit(1);  // exec failed
        }

        // Parent process — also set child's process group (race-free with child's setpgid)
        setpgid(childPid_, childPid_);

        close(stderrPipe[1]);   // child writes stderr
        stderrFd_ = stderrPipe[0];

        // Start stderr capture thread
        stderrThread_ = std::thread(&IpcBridge::StderrReadLoop, this);

        // Accept worklet connection (with timeout)
        struct timeval tv;
        tv.tv_sec = 15;
        tv.tv_usec = 0;
        setsockopt(listenSock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        childIpcFd_ = accept(listenSock, nullptr, nullptr);
        if (childIpcFd_ < 0) {
            std::cerr << "[ipc] accept() failed (worklet didn't connect): "
                      << strerror(errno) << std::endl;
            // Don't return false — fall through to Node fallback
            close(listenSock);
            unlink(ipcSocketPath_.c_str());
            listenFd_ = -1;
            TerminateProcess();
            launchMode_ = WorkletLaunchMode::Node;
            return LaunchProcess();
        }

        // Close listening socket — we only need the one connection
        close(listenSock);
        listenFd_ = -1;

        // Set socket buffer sizes
        int bufSize = 1024 * 1024;
        setsockopt(childIpcFd_, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));
        setsockopt(childIpcFd_, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));

        std::cerr << "[ipc] Worklet connected via UDS: " << ipcSocketPath_ << std::endl;

        return true;
    }

    // --- Node fallback mode: stdin/stdout pipes ---
    int stdinPipe[2];
    int stdoutPipe[2];

    if (pipe(stdinPipe) != 0) {
        std::cerr << "[ipc] pipe(stdin) failed: " << strerror(errno) << std::endl;
        return false;
    }
    if (pipe(stdoutPipe) != 0) {
        std::cerr << "[ipc] pipe(stdout) failed: " << strerror(errno) << std::endl;
        close(stdinPipe[0]); close(stdinPipe[1]);
        return false;
    }

    childPid_ = fork();
    if (childPid_ < 0) {
        std::cerr << "[ipc] fork() failed: " << strerror(errno) << std::endl;
        close(stdinPipe[0]); close(stdinPipe[1]);
        close(stdoutPipe[0]); close(stdoutPipe[1]);
        return false;
    }

    if (childPid_ == 0) {
        // Child process
        close(stdinPipe[1]);   // close write end of stdin pipe
        close(stdoutPipe[0]);  // close read end of stdout pipe

        dup2(stdinPipe[0], STDIN_FILENO);
        dup2(stdoutPipe[1], STDOUT_FILENO);
        // Keep stderr inherited

        close(stdinPipe[0]);
        close(stdoutPipe[1]);

        execlp(nodePath_.c_str(), nodePath_.c_str(), workletPath_.c_str(), nullptr);
        _exit(1);  // exec failed
    }

    // Parent process
    close(stdinPipe[0]);   // close read end of stdin pipe
    close(stdoutPipe[1]);  // close write end of stdout pipe

    childStdinFd_  = stdinPipe[1];
    childStdoutFd_ = stdoutPipe[0];

    // Maximize pipe buffer sizes (default is 64KB, we want 1MB)
    fcntl(childStdinFd_, F_SETPIPE_SZ, 1024 * 1024);
    fcntl(childStdoutFd_, F_SETPIPE_SZ, 1024 * 1024);

    return true;
}

void IpcBridge::TerminateProcess() {
    // Close IPC handles
    if (childIpcFd_ != -1) {
        close(childIpcFd_);
        childIpcFd_ = -1;
    }
    if (childStdinFd_ != -1) {
        close(childStdinFd_);
        childStdinFd_ = -1;
    }

    if (childPid_ > 0) {
        // Kill the entire process group (pear run spawns children).
        // Negative pid = kill process group.
        kill(-childPid_, SIGTERM);
        for (int i = 0; i < 20; ++i) {
            int status;
            if (waitpid(childPid_, &status, WNOHANG) != 0) goto done;
            usleep(100000);  // 100ms
        }
        // Force kill process group if still alive
        kill(-childPid_, SIGKILL);
        waitpid(childPid_, nullptr, 0);
    done:
        childPid_ = -1;
    }

    if (childStdoutFd_ != -1) {
        close(childStdoutFd_);
        childStdoutFd_ = -1;
    }
    if (stderrFd_ != -1) {
        close(stderrFd_);
        stderrFd_ = -1;
    }
    if (listenFd_ != -1) {
        close(listenFd_);
        listenFd_ = -1;
    }
    if (!ipcSocketPath_.empty()) {
        unlink(ipcSocketPath_.c_str());
        ipcSocketPath_.clear();
        // Clean up the well-known file
        std::string homeDir = getenv("HOME") ? getenv("HOME") : "/tmp";
        unlink((homeDir + "/.peariscope/ipc-sock").c_str());
    }
}

// ==========================================================================
// Stderr capture (Pear mode)
// ==========================================================================

void IpcBridge::StderrReadLoop() {
    if (stderrFd_ == -1) return;

    char buf[4096];
    std::string lineBuf;

    while (!stopping_.load(std::memory_order_acquire)) {
        ssize_t n = read(stderrFd_, buf, sizeof(buf));
        if (n <= 0) break;

        lineBuf.append(buf, n);
        size_t pos;
        while ((pos = lineBuf.find('\n')) != std::string::npos) {
            std::string line = lineBuf.substr(0, pos);
            lineBuf.erase(0, pos + 1);
            if (!line.empty() && onLog) {
                onLog("[worklet-stderr] " + line);
            }
        }
    }

    // Flush remaining
    if (!lineBuf.empty() && onLog) {
        onLog("[worklet-stderr] " + lineBuf);
    }
}

// ==========================================================================
// Write path
// ==========================================================================

void IpcBridge::SendCommand(NativeMsg type,
                            const std::string& json,
                            const uint8_t* binary,
                            size_t binaryLen)
{
    if (!running_.load(std::memory_order_acquire)) return;

    // Build payload: 1B type + (json | binary)
    std::vector<uint8_t> payload;
    payload.push_back(static_cast<uint8_t>(type));

    if (binary && binaryLen > 0) {
        payload.insert(payload.end(), binary, binary + binaryLen);
    } else if (!json.empty()) {
        payload.insert(payload.end(), json.begin(), json.end());
    }

    // Build frame: 4B length (BE) + payload
    uint32_t payloadLen = static_cast<uint32_t>(payload.size());
    std::vector<uint8_t> frame(4 + payload.size());
    WriteU32BE(frame.data(), payloadLen);
    std::memcpy(frame.data() + 4, payload.data(), payload.size());

    std::lock_guard<std::mutex> lk(writeMutex_);

    // Backpressure: drop video STREAM_DATA frames when write buffer is too full
    if (type == NativeMsg::StreamData &&
        pendingWrite_.size() > kMaxPendingWriteBytes)
    {
        ++droppedFrameCount_;
        if (droppedFrameCount_ <= 10 || droppedFrameCount_ % 100 == 0) {
            std::cerr << "[ipc-write] backpressure: dropping frame, pending="
                      << pendingWrite_.size() << " dropped="
                      << droppedFrameCount_ << std::endl;
        }
        return;
    }

    pendingWrite_.insert(pendingWrite_.end(), frame.begin(), frame.end());
    writeCv_.notify_one();
}

void IpcBridge::FlushPendingWrites() {
    // Must be called with writeMutex_ held.
    int fd = WriteFd();
    while (!pendingWrite_.empty() && fd != -1) {
        size_t toWrite = std::min(pendingWrite_.size(), size_t(1024 * 1024));
        ssize_t written = write(fd, pendingWrite_.data(), toWrite);

        if (written < 0) {
            if (errno == EPIPE || errno == ECONNRESET) {
                running_.store(false, std::memory_order_release);
            }
            break;
        }
        if (written == 0) break;

        if (static_cast<size_t>(written) >= pendingWrite_.size()) {
            pendingWrite_.clear();
        } else {
            pendingWrite_.erase(pendingWrite_.begin(),
                                pendingWrite_.begin() + written);
        }
    }
}

void IpcBridge::WriteLoop() {
    while (!stopping_.load(std::memory_order_acquire)) {
        std::unique_lock<std::mutex> lk(writeMutex_);
        writeCv_.wait_for(lk, std::chrono::milliseconds(1), [this]() {
            return !pendingWrite_.empty() || stopping_.load(std::memory_order_acquire);
        });
        if (stopping_.load(std::memory_order_acquire)) break;
        FlushPendingWrites();
    }
}

// ==========================================================================
// Public command methods
// ==========================================================================

void IpcBridge::StartHosting(const std::string& deviceCode) {
    if (deviceCode.empty()) {
        SendCommand(NativeMsg::StartHosting, "{}");
    } else {
        SendCommand(NativeMsg::StartHosting,
                    JsonObject({{"deviceCode", deviceCode}}));
    }
}

void IpcBridge::StopHosting() {
    SendCommand(NativeMsg::StopHosting);
}

void IpcBridge::ConnectToPeer(const std::string& code) {
    SendCommand(NativeMsg::ConnectToPeer,
                JsonObject({{"code", code}}));
}

void IpcBridge::Disconnect(const std::string& peerKeyHex) {
    SendCommand(NativeMsg::Disconnect,
                JsonObject({{"peerKeyHex", peerKeyHex}}));
}

void IpcBridge::SendStreamData(uint32_t streamId, uint8_t channel,
                               const uint8_t* data, size_t size)
{
    if (size <= kMaxChunkPayload) {
        // Unchunked: streamId(4B) + channel(1B) + totalChunks=0(2B) + data
        std::vector<uint8_t> payload(4 + 1 + 2 + size);
        WriteU32BE(payload.data(), streamId);
        payload[4] = channel;
        payload[5] = 0; // totalChunks high = 0
        payload[6] = 0; // totalChunks low  = 0
        std::memcpy(payload.data() + 7, data, size);
        SendCommand(NativeMsg::StreamData, {}, payload.data(), payload.size());
        return;
    }

    // Chunked: build ALL chunk frames first, then write atomically.
    // This prevents partial frame drops when backpressure triggers mid-frame,
    // which caused decoder corruption (partial NAL units -> persistent artifacts).
    size_t totalChunks = (size + kMaxChunkPayload - 1) / kMaxChunkPayload;

    // Pre-build all chunk frames into a single buffer
    std::vector<uint8_t> allFrames;
    allFrames.reserve(totalChunks * (4 + 1 + 4 + 1 + 2 + 2 + kMaxChunkPayload));

    for (size_t i = 0; i < totalChunks; ++i) {
        size_t offset = i * kMaxChunkPayload;
        size_t chunkLen = std::min(kMaxChunkPayload, size - offset);

        // Build payload: streamId(4B) + channel(1B) + totalChunks(2B) + chunkIndex(2B) + data
        size_t payloadSize = 4 + 1 + 2 + 2 + chunkLen;

        // Build IPC frame: 4B length (BE) + 1B type + payload
        size_t frameSize = 4 + 1 + payloadSize;
        size_t frameStart = allFrames.size();
        allFrames.resize(frameStart + frameSize);
        uint8_t* fp = allFrames.data() + frameStart;

        WriteU32BE(fp, static_cast<uint32_t>(1 + payloadSize)); // length = type + payload
        fp[4] = static_cast<uint8_t>(NativeMsg::StreamData);
        WriteU32BE(fp + 5, streamId);
        fp[9] = channel;
        WriteU16BE(fp + 10, static_cast<uint16_t>(totalChunks));
        WriteU16BE(fp + 12, static_cast<uint16_t>(i));
        std::memcpy(fp + 14, data + offset, chunkLen);
    }

    // Atomic write: either all chunks go or none do
    std::lock_guard<std::mutex> lk(writeMutex_);

    if (pendingWrite_.size() + allFrames.size() > kMaxPendingWriteBytes) {
        ++droppedFrameCount_;
        if (droppedFrameCount_ <= 10 || droppedFrameCount_ % 100 == 0) {
            std::cerr << "[ipc-write] backpressure: dropping ENTIRE chunked frame ("
                      << totalChunks << " chunks, " << size << " bytes), pending="
                      << pendingWrite_.size() << " dropped="
                      << droppedFrameCount_ << std::endl;
        }
        return;
    }

    pendingWrite_.insert(pendingWrite_.end(), allFrames.begin(), allFrames.end());
    writeCv_.notify_one();
}

void IpcBridge::RequestStatus() {
    SendCommand(NativeMsg::StatusRequest);
}

void IpcBridge::LookupPeer(const std::string& code) {
    SendCommand(NativeMsg::LookupPeer,
                JsonObject({{"code", code}}));
}

void IpcBridge::SendCachedDhtNodes() {
    // Load cached DHT nodes from ~/.peariscope/dht-nodes.json and send to worklet
    try {
        const char* home = std::getenv("HOME");
        if (!home || home[0] == '\0') return;

        std::filesystem::path cachePath = std::filesystem::path(home) / ".peariscope" / "dht-nodes.json";
        if (!std::filesystem::exists(cachePath)) return;

        std::ifstream ifs(cachePath);
        if (!ifs.is_open()) return;

        std::string nodesJson((std::istreambuf_iterator<char>(ifs)),
                               std::istreambuf_iterator<char>());
        ifs.close();

        if (nodesJson.empty() || nodesJson[0] != '[') return;

        // Wrap in {"nodes": ...} envelope
        std::string payload = "{\"nodes\":" + nodesJson + "}";
        SendCommand(NativeMsg::CachedDhtNodes, payload);

        if (onLog) onLog("[IpcBridge] Sent cached DHT nodes to worklet");
    } catch (const std::exception& e) {
        if (onLog) onLog(std::string("[IpcBridge] SendCachedDhtNodes error: ") + e.what());
    }
}

void IpcBridge::Suspend() {
    SendCommand(NativeMsg::Suspend);
}

void IpcBridge::Resume() {
    SendCommand(NativeMsg::Resume);
}

void IpcBridge::Reannounce() {
    SendCommand(NativeMsg::Reannounce);
}

void IpcBridge::ApprovePeer(const std::string& peerKeyHex, bool approved) {
    SendCommand(NativeMsg::ApprovePeer,
                JsonObject({{"peerKeyHex", peerKeyHex},
                            {"approved", approved ? "true" : "false"}}));
}

bool IpcBridge::IsAlive() const {
    if (!running_.load(std::memory_order_acquire)) return false;
    if (childPid_ <= 0) return false;
    return kill(childPid_, 0) == 0;
}

// ==========================================================================
// Read path
// ==========================================================================

void IpcBridge::ReadLoop() {
    constexpr size_t kBufSize = 65536;
    uint8_t buf[kBufSize];

    int fd = ReadFd();

    while (!stopping_.load(std::memory_order_acquire)) {
        ssize_t bytesRead = read(fd, buf, kBufSize);

        if (bytesRead <= 0) {
            // 0 = EOF (child exited), negative = error
            running_.store(false, std::memory_order_release);
            break;
        }

        recvBuf_.insert(recvBuf_.end(), buf, buf + bytesRead);
        DrainFrames();
    }
}

void IpcBridge::DrainFrames() {
    while (recvBuf_.size() - recvBufOffset_ >= 4) {
        uint32_t length = ReadU32BE(recvBuf_.data() + recvBufOffset_);

        if (length > kMaxFrameLength) {
            std::cerr << "[ipc] ERROR: frame length " << length
                      << " exceeds max, dropping buffer" << std::endl;
            recvBuf_.clear();
            recvBufOffset_ = 0;
            return;
        }

        if (recvBuf_.size() - recvBufOffset_ < 4 + length) {
            break; // incomplete frame
        }

        const uint8_t* framePtr = recvBuf_.data() + recvBufOffset_ + 4;
        HandleFrame(framePtr, length);

        recvBufOffset_ += 4 + length;
    }

    // Compact when we have consumed a significant portion
    if (recvBufOffset_ > 65536) {
        recvBuf_.erase(recvBuf_.begin(),
                       recvBuf_.begin() + recvBufOffset_);
        recvBufOffset_ = 0;
    }
}

// ==========================================================================
// Frame dispatch
// ==========================================================================

void IpcBridge::HandleFrame(const uint8_t* data, size_t size) {
    if (size < 1) return;

    uint8_t typeRaw = data[0];
    const uint8_t* rest = data + 1;
    size_t restLen = size - 1;

    auto parseJson = [&]() -> std::unordered_map<std::string, std::string> {
        std::string s(reinterpret_cast<const char*>(rest), restLen);
        return ParseJsonFlat(s);
    };

    switch (static_cast<WorkletMsg>(typeRaw)) {
    // ------------------------------------------------------------------
    case WorkletMsg::HostingStarted: {
        if (onHostingStarted) {
            auto j = parseJson();
            HostingStartedEvent ev;
            ev.publicKeyHex   = GetStr(j, "publicKeyHex");
            ev.connectionCode = GetStr(j, "connectionCode");
            ev.qrMatrix       = GetStr(j, "qrMatrix");
            ev.qrSize         = static_cast<int>(GetInt(j, "qrSize"));
            onHostingStarted(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::HostingStopped: {
        if (onHostingStopped) onHostingStopped();
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::ConnectionEstablished: {
        if (onConnectionEstablished) {
            auto j = parseJson();
            ConnectionEstablishedEvent ev;
            ev.peerKeyHex = GetStr(j, "peerKeyHex");
            ev.streamId   = static_cast<uint32_t>(GetInt(j, "streamId"));
            onConnectionEstablished(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::ConnectionFailed: {
        if (onConnectionFailed) {
            auto j = parseJson();
            ConnectionFailedEvent ev;
            ev.code      = GetStr(j, "code");
            ev.reason    = GetStr(j, "reason");
            ev.errorType = GetStr(j, "errorType");
            onConnectionFailed(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::PeerConnected: {
        if (onPeerConnected) {
            auto j = parseJson();
            PeerConnectedEvent ev;
            ev.peerKeyHex = GetStr(j, "peerKeyHex");
            ev.peerName   = GetStr(j, "peerName");
            ev.streamId   = static_cast<uint32_t>(GetInt(j, "streamId"));
            onPeerConnected(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::PeerDisconnected: {
        if (onPeerDisconnected) {
            auto j = parseJson();
            PeerDisconnectedEvent ev;
            ev.peerKeyHex = GetStr(j, "peerKeyHex");
            ev.reason     = GetStr(j, "reason");
            onPeerDisconnected(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::StreamData: {
        // Hybrid format: 2B JSON length (UInt16 BE) + JSON + binary data
        // (The 1-byte type has already been consumed into typeRaw.)
        if (restLen < 2) break;

        uint16_t jsonLen = ReadU16BE(rest);
        if (restLen < 2u + jsonLen) break;

        std::string jsonStr(reinterpret_cast<const char*>(rest + 2), jsonLen);
        const uint8_t* binaryPtr = rest + 2 + jsonLen;
        size_t binaryLen = restLen - 2 - jsonLen;

        auto j = ParseJsonFlat(jsonStr);
        uint32_t streamId = static_cast<uint32_t>(GetInt(j, "streamId"));
        uint8_t  channel  = static_cast<uint8_t>(GetInt(j, "channel"));

        // Security: drop input (ch1) and audio (ch3) from blocked peers.
        // Control (ch2) is NOT blocked so PIN responses can reach the host.
        if ((channel == 1 || channel == 3) &&
            blockedStreamIds.count(streamId)) {
            break;
        }

        int64_t totalChunks = GetInt(j, "_totalChunks");
        int64_t chunkIndex  = GetInt(j, "_chunkIndex");

        if (totalChunks > 1 && chunkIndex >= 0) {
            // Chunked reassembly
            std::string key = std::to_string(streamId) + ":" +
                              std::to_string(channel);

            // Evict expired buffers if we have too many
            if (chunkBuffers_.size() >
                static_cast<size_t>(kMaxPendingChunkBuffers / 2))
            {
                for (auto it = chunkBuffers_.begin();
                     it != chunkBuffers_.end();)
                {
                    if (it->second.IsExpired())
                        it = chunkBuffers_.erase(it);
                    else
                        ++it;
                }
            }

            // Create buffer on first chunk
            if (chunkIndex == 0 &&
                static_cast<int>(totalChunks) <= kMaxChunksPerBuffer &&
                static_cast<int>(chunkBuffers_.size()) < kMaxPendingChunkBuffers)
            {
                ChunkBuffer cb;
                cb.total = static_cast<int>(totalChunks);
                cb.createdTick = MonotonicMs();
                chunkBuffers_[key] = std::move(cb);
            }

            auto it = chunkBuffers_.find(key);
            if (it != chunkBuffers_.end() &&
                chunkIndex < it->second.total)
            {
                it->second.chunks[static_cast<int>(chunkIndex)] =
                    std::vector<uint8_t>(binaryPtr, binaryPtr + binaryLen);

                if (it->second.IsComplete()) {
                    auto assembled = it->second.Assemble();
                    chunkBuffers_.erase(it);

                    if (onStreamData) {
                        StreamDataEvent ev;
                        ev.streamId = streamId;
                        ev.channel  = channel;
                        ev.data     = std::move(assembled);
                        onStreamData(ev);
                    }
                }
            }
        } else {
            // Unchunked
            if (onStreamData) {
                StreamDataEvent ev;
                ev.streamId = streamId;
                ev.channel  = channel;
                ev.data.assign(binaryPtr, binaryPtr + binaryLen);
                onStreamData(ev);
            }
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::StatusResponse: {
        if (onStatusResponse) {
            auto j = parseJson();
            StatusEvent ev;
            ev.isHosting   = GetBool(j, "isHosting");
            ev.isConnected = GetBool(j, "isConnected");
            ev.json = std::string(reinterpret_cast<const char*>(rest), restLen);
            onStatusResponse(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::Error: {
        if (onError) {
            auto j = parseJson();
            onError(GetStr(j, "message"));
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::Log: {
        if (onLog) {
            auto j = parseJson();
            onLog(GetStr(j, "message"));
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::LookupResult: {
        if (onLookupResult) {
            auto j = parseJson();
            LookupResultEvent ev;
            ev.code   = GetStr(j, "code");
            ev.online = GetBool(j, "online");
            onLookupResult(ev);
        }
        break;
    }

    case WorkletMsg::DhtNodes: {
        // Worklet sends DHT routing table for native-side persistence
        // Raw JSON is {"nodes":[{"host":"...","port":...},...]}
        // Extract the nodes array and save directly to file
        std::string rawJson(reinterpret_cast<const char*>(rest), restLen);
        try {
            // Find "nodes": and extract the array
            auto nodesPos = rawJson.find("\"nodes\"");
            if (nodesPos != std::string::npos) {
                auto arrStart = rawJson.find('[', nodesPos);
                if (arrStart != std::string::npos) {
                    // Find matching closing bracket
                    int depth = 0;
                    size_t arrEnd = arrStart;
                    for (size_t i = arrStart; i < rawJson.size(); ++i) {
                        if (rawJson[i] == '[') depth++;
                        else if (rawJson[i] == ']') { depth--; if (depth == 0) { arrEnd = i; break; } }
                    }
                    std::string nodesArray = rawJson.substr(arrStart, arrEnd - arrStart + 1);

                    const char* home = std::getenv("HOME");
                    if (home && home[0] != '\0') {
                        auto cacheDir = std::filesystem::path(home) / ".peariscope";
                        std::filesystem::create_directories(cacheDir);
                        auto cachePath = cacheDir / "dht-nodes.json";
                        std::ofstream ofs(cachePath);
                        if (ofs.is_open()) {
                            ofs << nodesArray;
                            ofs.close();
                        }
                    }
                }
            }
        } catch (const std::exception& e) {
            if (onLog) onLog(std::string("[IpcBridge] DHT cache save error: ") + e.what());
        }
        if (onDhtNodes) {
            onDhtNodes(rawJson);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::UpdateAvailable: {
        if (onUpdateAvailable) {
            auto j = parseJson();
            UpdateAvailableEvent ev;
            ev.version      = GetStr(j, "version");
            ev.downloadPath = GetStr(j, "downloadPath");
            ev.component    = GetStr(j, "component");
            onUpdateAvailable(ev);
        }
        break;
    }

    // ------------------------------------------------------------------
    case WorkletMsg::ConnectionState: {
        if (onConnectionState) {
            auto j = parseJson();
            ConnectionStateEvent ev;
            ev.state       = GetStr(j, "state");
            ev.detail      = GetStr(j, "detail");
            ev.attempt     = GetInt(j, "attempt");
            ev.maxAttempts = GetInt(j, "maxAttempts");
            onConnectionState(ev);
        }
        break;
    }

    default:
        std::cerr << "[ipc] Unknown message type: 0x"
                  << std::hex << static_cast<int>(typeRaw) << std::dec
                  << std::endl;
        break;
    }
}

// ==========================================================================
// ChunkBuffer helpers
// ==========================================================================

bool IpcBridge::ChunkBuffer::IsExpired() const {
    return (MonotonicMs() - createdTick) > kChunkExpiryMs;
}

std::vector<uint8_t> IpcBridge::ChunkBuffer::Assemble() const {
    // Calculate total size first
    size_t totalSize = 0;
    for (int i = 0; i < total; ++i) {
        auto it = chunks.find(i);
        if (it != chunks.end()) totalSize += it->second.size();
    }

    std::vector<uint8_t> result;
    result.reserve(totalSize);
    for (int i = 0; i < total; ++i) {
        auto it = chunks.find(i);
        if (it != chunks.end()) {
            result.insert(result.end(),
                          it->second.begin(), it->second.end());
        }
    }
    return result;
}

} // namespace peariscope
