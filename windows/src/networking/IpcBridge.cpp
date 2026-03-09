#include "IpcBridge.h"

#include <algorithm>
#include <cassert>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <stdexcept>

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
            else if (s[pos] == '"') ReadJsonString(s, pos--); // re-read will ++pos
            ++pos;
        }
        return;
    }
    if (s[pos] == '[') {
        int depth = 1; ++pos;
        while (pos < s.size() && depth > 0) {
            if (s[pos] == '[') ++depth;
            else if (s[pos] == ']') --depth;
            else if (s[pos] == '"') ReadJsonString(s, pos--);
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

} // anonymous namespace

namespace peariscope {

// ==========================================================================
// Construction / destruction
// ==========================================================================

IpcBridge::IpcBridge(const std::string& nodePath,
                     const std::string& workletPath)
    : nodePath_(nodePath)
    , workletPath_(workletPath.empty() ? ResolveWorkletPath() : workletPath)
{}

IpcBridge::~IpcBridge() {
    Stop();
}

// ==========================================================================
// Worklet path resolution
// ==========================================================================

std::string IpcBridge::ResolveWorkletPath() {
    // Resolve worklet.js relative to the running executable.
    wchar_t exePath[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::filesystem::path p(exePath);
    auto candidate = p.parent_path() / "pear" / "worklet.js";
    return candidate.string();
}

// ==========================================================================
// Subprocess lifecycle
// ==========================================================================

bool IpcBridge::Start() {
    if (running_.load(std::memory_order_acquire)) return true;

    if (!LaunchProcess()) return false;

    running_.store(true, std::memory_order_release);
    stopping_.store(false, std::memory_order_release);

    readThread_ = std::thread(&IpcBridge::ReadLoop, this);

    return true;
}

void IpcBridge::Stop() {
    if (!running_.load(std::memory_order_acquire)) return;

    stopping_.store(true, std::memory_order_release);
    running_.store(false, std::memory_order_release);

    TerminateProcess();

    if (readThread_.joinable()) {
        readThread_.join();
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
    // Create pipes for child stdin/stdout.
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    // Child stdin: we write to hChildStdinWr_, child reads hChildStdinRd_
    if (!CreatePipe(&hChildStdinRd_, &hChildStdinWr_, &sa, 0)) {
        std::cerr << "[ipc] CreatePipe(stdin) failed: " << GetLastError() << std::endl;
        return false;
    }
    // Child stdout: child writes hChildStdoutWr_, we read hChildStdoutRd_
    if (!CreatePipe(&hChildStdoutRd_, &hChildStdoutWr_, &sa, 0)) {
        std::cerr << "[ipc] CreatePipe(stdout) failed: " << GetLastError() << std::endl;
        CloseHandle(hChildStdinRd_); CloseHandle(hChildStdinWr_);
        return false;
    }

    // Ensure our ends of the pipes are NOT inherited by the child.
    SetHandleInformation(hChildStdinWr_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hChildStdoutRd_, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput  = hChildStdinRd_;
    si.hStdOutput = hChildStdoutWr_;
    si.hStdError  = GetStdHandle(STD_ERROR_HANDLE); // inherit parent stderr

    PROCESS_INFORMATION pi{};

    std::string cmdLine = "\"" + nodePath_ + "\" \"" + workletPath_ + "\"";

    if (!CreateProcessA(
            nullptr,
            cmdLine.data(),
            nullptr, nullptr,
            TRUE,                       // inherit handles
            CREATE_NO_WINDOW,           // no console window
            nullptr, nullptr,
            &si, &pi))
    {
        std::cerr << "[ipc] CreateProcess failed: " << GetLastError()
                  << " cmd=" << cmdLine << std::endl;
        CloseHandle(hChildStdinRd_);  CloseHandle(hChildStdinWr_);
        CloseHandle(hChildStdoutRd_); CloseHandle(hChildStdoutWr_);
        return false;
    }

    hProcess_ = pi.hProcess;
    CloseHandle(pi.hThread);

    // Close the child-side handles in the parent process.
    CloseHandle(hChildStdinRd_);   hChildStdinRd_  = INVALID_HANDLE_VALUE;
    CloseHandle(hChildStdoutWr_);  hChildStdoutWr_ = INVALID_HANDLE_VALUE;

    return true;
}

void IpcBridge::TerminateProcess() {
    // Close our write handle so the child's stdin gets EOF.
    if (hChildStdinWr_ != INVALID_HANDLE_VALUE) {
        CloseHandle(hChildStdinWr_);
        hChildStdinWr_ = INVALID_HANDLE_VALUE;
    }

    if (hProcess_ != INVALID_HANDLE_VALUE) {
        // Give the child a brief window to exit cleanly before forcing.
        if (WaitForSingleObject(hProcess_, 2000) == WAIT_TIMEOUT) {
            ::TerminateProcess(hProcess_, 1);
            WaitForSingleObject(hProcess_, 1000);
        }
        CloseHandle(hProcess_);
        hProcess_ = INVALID_HANDLE_VALUE;
    }

    if (hChildStdoutRd_ != INVALID_HANDLE_VALUE) {
        CloseHandle(hChildStdoutRd_);
        hChildStdoutRd_ = INVALID_HANDLE_VALUE;
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
    FlushPendingWrites();
}

void IpcBridge::FlushPendingWrites() {
    // Must be called with writeMutex_ held.
    while (!pendingWrite_.empty() && hChildStdinWr_ != INVALID_HANDLE_VALUE) {
        DWORD toWrite = static_cast<DWORD>(
            (std::min)(pendingWrite_.size(), size_t(1024 * 1024)));
        DWORD written = 0;
        if (!WriteFile(hChildStdinWr_, pendingWrite_.data(), toWrite,
                       &written, nullptr))
        {
            DWORD err = GetLastError();
            if (err == ERROR_BROKEN_PIPE || err == ERROR_NO_DATA) {
                running_.store(false, std::memory_order_release);
            }
            break;
        }
        if (written == 0) break;

        if (written >= pendingWrite_.size()) {
            pendingWrite_.clear();
        } else {
            pendingWrite_.erase(pendingWrite_.begin(),
                                pendingWrite_.begin() + written);
        }
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

    // Chunked: split into kMaxChunkPayload pieces
    size_t totalChunks = (size + kMaxChunkPayload - 1) / kMaxChunkPayload;
    for (size_t i = 0; i < totalChunks; ++i) {
        size_t offset = i * kMaxChunkPayload;
        size_t chunkLen = (std::min)(kMaxChunkPayload, size - offset);

        // streamId(4B) + channel(1B) + totalChunks(2B) + chunkIndex(2B) + data
        std::vector<uint8_t> payload(4 + 1 + 2 + 2 + chunkLen);
        WriteU32BE(payload.data(), streamId);
        payload[4] = channel;
        WriteU16BE(payload.data() + 5, static_cast<uint16_t>(totalChunks));
        WriteU16BE(payload.data() + 7, static_cast<uint16_t>(i));
        std::memcpy(payload.data() + 9, data + offset, chunkLen);
        SendCommand(NativeMsg::StreamData, {}, payload.data(), payload.size());
    }
}

void IpcBridge::RequestStatus() {
    SendCommand(NativeMsg::StatusRequest);
}

void IpcBridge::LookupPeer(const std::string& code) {
    SendCommand(NativeMsg::LookupPeer,
                JsonObject({{"code", code}}));
}

bool IpcBridge::IsAlive() const {
    if (!running_.load(std::memory_order_acquire)) return false;
    if (hProcess_ == INVALID_HANDLE_VALUE) return false;
    DWORD exitCode = 0;
    if (GetExitCodeProcess(hProcess_, &exitCode)) {
        return exitCode == STILL_ACTIVE;
    }
    return false;
}

// ==========================================================================
// Read path
// ==========================================================================

void IpcBridge::ReadLoop() {
    constexpr DWORD kBufSize = 65536;
    uint8_t buf[kBufSize];

    while (!stopping_.load(std::memory_order_acquire)) {
        DWORD bytesRead = 0;
        BOOL ok = ReadFile(hChildStdoutRd_, buf, kBufSize, &bytesRead, nullptr);

        if (!ok || bytesRead == 0) {
            DWORD err = GetLastError();
            if (err == ERROR_BROKEN_PIPE || !ok) {
                // Child exited or pipe closed.
                running_.store(false, std::memory_order_release);
                break;
            }
            continue;
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
            ev.publicKeyHex  = GetStr(j, "publicKeyHex");
            ev.connectionCode = GetStr(j, "connectionCode");
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
            ev.code   = GetStr(j, "code");
            ev.reason = GetStr(j, "reason");
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
                cb.createdTick = GetTickCount64();
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
    return (GetTickCount64() - createdTick) > kChunkExpiryMs;
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
