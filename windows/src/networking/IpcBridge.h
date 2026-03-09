#pragma once

#include <Windows.h>
#include <functional>
#include <vector>
#include <string>
#include <thread>
#include <mutex>
#include <atomic>
#include <cstdint>
#include <unordered_map>

namespace peariscope {

// ---------------------------------------------------------------------------
// Message types: Native -> Worklet
// ---------------------------------------------------------------------------
enum class NativeMsg : uint8_t {
    StartHosting   = 0x01,
    StopHosting    = 0x02,
    ConnectToPeer  = 0x03,
    Disconnect     = 0x04,
    StreamData     = 0x05,
    StatusRequest  = 0x06,
    LookupPeer     = 0x07,
};

// ---------------------------------------------------------------------------
// Message types: Worklet -> Native
// ---------------------------------------------------------------------------
enum class WorkletMsg : uint8_t {
    HostingStarted          = 0x81,
    HostingStopped          = 0x82,
    ConnectionEstablished   = 0x83,
    ConnectionFailed        = 0x84,
    PeerConnected           = 0x85,
    PeerDisconnected        = 0x86,
    StreamData              = 0x87,
    StatusResponse          = 0x88,
    Error                   = 0x89,
    Log                     = 0x8A,
    LookupResult            = 0x8B,
};

// ---------------------------------------------------------------------------
// Event structs
// ---------------------------------------------------------------------------

struct HostingStartedEvent {
    std::string publicKeyHex;
    std::string connectionCode;
};

struct ConnectionEstablishedEvent {
    std::string peerKeyHex;
    uint32_t    streamId = 0;
};

struct ConnectionFailedEvent {
    std::string code;
    std::string reason;
};

struct PeerConnectedEvent {
    std::string peerKeyHex;
    std::string peerName;
    uint32_t    streamId = 0;
};

struct PeerDisconnectedEvent {
    std::string peerKeyHex;
    std::string reason;
};

struct StreamDataEvent {
    uint32_t             streamId = 0;
    uint8_t              channel  = 0;
    std::vector<uint8_t> data;
};

struct StatusEvent {
    bool isHosting   = false;
    bool isConnected = false;
    std::string json; // raw JSON for peers array
};

struct LookupResultEvent {
    std::string code;
    bool online = false;
};

// ---------------------------------------------------------------------------
// IpcBridge
// ---------------------------------------------------------------------------

/// IPC bridge that launches a Node.js subprocess running the Pear worklet
/// and communicates via stdin/stdout using BareKit-compatible length-prefixed
/// binary frames.
class IpcBridge {
public:
    /// @param nodePath   Path to node.exe (default: "node" on PATH)
    /// @param workletPath Path to worklet.js (default: resolved relative to exe)
    explicit IpcBridge(const std::string& nodePath   = "node",
                       const std::string& workletPath = "");
    ~IpcBridge();

    IpcBridge(const IpcBridge&) = delete;
    IpcBridge& operator=(const IpcBridge&) = delete;

    /// Launch the worklet subprocess and start the read loop.
    bool Start();

    /// Gracefully shut down the subprocess and join threads.
    void Stop();

    bool IsRunning() const { return running_.load(std::memory_order_acquire); }

    /// Check if the worklet process is alive and running.
    bool IsAlive() const;

    // -- Commands (native -> worklet) ----------------------------------------

    void StartHosting(const std::string& deviceCode = "");
    void StopHosting();
    void ConnectToPeer(const std::string& code);
    void Disconnect(const std::string& peerKeyHex);
    void SendStreamData(uint32_t streamId, uint8_t channel,
                        const uint8_t* data, size_t size);
    void RequestStatus();
    void LookupPeer(const std::string& code);

    // -- Callbacks (worklet -> native) ---------------------------------------

    std::function<void(const HostingStartedEvent&)>          onHostingStarted;
    std::function<void()>                                    onHostingStopped;
    std::function<void(const ConnectionEstablishedEvent&)>   onConnectionEstablished;
    std::function<void(const ConnectionFailedEvent&)>        onConnectionFailed;
    std::function<void(const PeerConnectedEvent&)>           onPeerConnected;
    std::function<void(const PeerDisconnectedEvent&)>        onPeerDisconnected;
    std::function<void(const StreamDataEvent&)>              onStreamData;
    std::function<void(const StatusEvent&)>                  onStatusResponse;
    std::function<void(const std::string&)>                  onError;
    std::function<void(const std::string&)>                  onLog;
    std::function<void(const LookupResultEvent&)>            onLookupResult;

private:
    // -- Subprocess management -----------------------------------------------
    bool LaunchProcess();
    void TerminateProcess();

    // -- Write path ----------------------------------------------------------
    void SendCommand(NativeMsg type,
                     const std::string& json = {},
                     const uint8_t* binary = nullptr,
                     size_t binaryLen = 0);
    void FlushPendingWrites();

    // -- Read path -----------------------------------------------------------
    void ReadLoop();
    void DrainFrames();
    void HandleFrame(const uint8_t* data, size_t size);

    // -- Chunk reassembly ----------------------------------------------------
    struct ChunkBuffer {
        int                                   total = 0;
        ULONGLONG                             createdTick = 0;
        std::unordered_map<int, std::vector<uint8_t>> chunks;

        bool IsComplete() const { return static_cast<int>(chunks.size()) == total; }
        bool IsExpired() const;
        std::vector<uint8_t> Assemble() const;
    };
    std::unordered_map<std::string, ChunkBuffer> chunkBuffers_;

    // -- Worklet path resolution ---------------------------------------------
    static std::string ResolveWorkletPath();

    // -- Configuration -------------------------------------------------------
    std::string nodePath_;
    std::string workletPath_;

    // -- Subprocess handles --------------------------------------------------
    HANDLE hProcess_       = INVALID_HANDLE_VALUE;
    HANDLE hChildStdinRd_  = INVALID_HANDLE_VALUE;
    HANDLE hChildStdinWr_  = INVALID_HANDLE_VALUE;
    HANDLE hChildStdoutRd_ = INVALID_HANDLE_VALUE;
    HANDLE hChildStdoutWr_ = INVALID_HANDLE_VALUE;

    // -- Threading -----------------------------------------------------------
    std::thread          readThread_;
    std::mutex           writeMutex_;
    std::atomic<bool>    running_{false};
    std::atomic<bool>    stopping_{false};

    // -- Write buffer / backpressure -----------------------------------------
    std::vector<uint8_t> pendingWrite_;
    uint64_t             droppedFrameCount_ = 0;

    static constexpr size_t kMaxPendingWriteBytes  = 2 * 1024 * 1024; // 2MB for large keyframes
    static constexpr size_t kMaxChunkPayload       = 16000;
    static constexpr size_t kMaxFrameLength        = 5 * 1024 * 1024;
    static constexpr int    kMaxChunksPerBuffer     = 256;
    static constexpr int    kMaxPendingChunkBuffers = 16;
    static constexpr ULONGLONG kChunkExpiryMs       = 2000; // 2s

    // -- Recv buffer ---------------------------------------------------------
    std::vector<uint8_t> recvBuf_;
    size_t               recvBufOffset_ = 0;
};

} // namespace peariscope
