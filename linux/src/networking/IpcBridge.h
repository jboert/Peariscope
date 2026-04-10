#pragma once

#include <functional>
#include <vector>
#include <string>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <sys/types.h>

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
    LookupPeer       = 0x07,
    CachedDhtNodes   = 0x08,
    Suspend        = 0x09,
    Resume         = 0x0A,
    ApprovePeer    = 0x0B,
    Reannounce     = 0x0D,
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
    DhtNodes                = 0x8C,
    UpdateAvailable         = 0x8D,
    ConnectionState         = 0x8E,
};

// ---------------------------------------------------------------------------
// Event structs
// ---------------------------------------------------------------------------

struct HostingStartedEvent {
    std::string publicKeyHex;
    std::string connectionCode;
    std::string qrMatrix;  // flat string of '0'/'1' chars (row-major)
    int qrSize = 0;        // modules per side
};

struct ConnectionEstablishedEvent {
    std::string peerKeyHex;
    uint32_t    streamId = 0;
};

struct ConnectionFailedEvent {
    std::string code;
    std::string reason;
    std::string errorType; // "dht_timeout" or "holepunch_timeout"
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

struct UpdateAvailableEvent {
    std::string version;
    std::string downloadPath;
    std::string component; // "js" or "native"
};

struct ConnectionStateEvent {
    std::string state;   // "searching", "holepunching", "dht_error", "retrying"
    std::string detail;  // Human-readable status
    int attempt = 0;
    int maxAttempts = 0;
};

// ---------------------------------------------------------------------------
// Launch mode for the worklet subprocess
// ---------------------------------------------------------------------------
enum class WorkletLaunchMode {
    Node,      // node worklet.js (stdin/stdout IPC) -- fallback
    PearDev,   // pear run --dev <dir> (fd 3 socketpair IPC)
    PearProd,  // pear run pear://<key> (fd 3 socketpair IPC)
};

// ---------------------------------------------------------------------------
// IpcBridge
// ---------------------------------------------------------------------------

/// IPC bridge that launches a Node.js or Pear subprocess running the worklet
/// and communicates via fd 3 socketpair (Pear) or stdin/stdout pipes (Node).
class IpcBridge {
public:
    /// @param nodePath   Path to node binary (default: "node" on PATH)
    /// @param workletPath Path to worklet.js (default: resolved relative to exe)
    explicit IpcBridge(const std::string& nodePath   = "node",
                       const std::string& workletPath = "");
    ~IpcBridge();

    IpcBridge(const IpcBridge&) = delete;
    IpcBridge& operator=(const IpcBridge&) = delete;

    /// Set launch mode (must be called before Start())
    void SetLaunchMode(WorkletLaunchMode mode) { launchMode_ = mode; }
    WorkletLaunchMode GetLaunchMode() const { return launchMode_; }

    /// Set the Pear release key (for PearProd mode)
    void SetPearKey(const std::string& key) { pearKey_ = key; }

    /// Launch the worklet subprocess and start the read loop.
    bool Start();

    /// Gracefully shut down the subprocess and join threads.
    void Stop();

    bool IsRunning() const { return running_.load(std::memory_order_acquire); }

    /// Check if the worklet process is alive and running.
    bool IsAlive() const;

    /// Get the child process PID (for signal-safe cleanup).
    pid_t ChildPid() const { return childPid_; }

    // -- Commands (native -> worklet) ----------------------------------------

    void StartHosting(const std::string& deviceCode = "");
    void StopHosting();
    void ConnectToPeer(const std::string& code);
    void Disconnect(const std::string& peerKeyHex);
    void SendStreamData(uint32_t streamId, uint8_t channel,
                        const uint8_t* data, size_t size);
    void RequestStatus();
    void LookupPeer(const std::string& code);
    void SendCachedDhtNodes();
    void Suspend();
    void Resume();
    void Reannounce();
    void ApprovePeer(const std::string& peerKeyHex, bool approved);

    // -- Blocked stream IDs (security: block unverified peers) ----------------
    // When a peer connects and PIN verification is required, its streamId is
    // added here.  Channels 1 (input) and 3 (audio) are dropped for any
    // streamId in this set.  Channel 2 (control) is NOT blocked so the
    // viewer can send its PIN response.  Remove the streamId when the peer
    // is approved, rejected, or disconnects.
    std::unordered_set<uint32_t> blockedStreamIds;

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
    std::function<void(const std::string&)>                  onDhtNodes; // raw JSON of nodes array
    std::function<void(const UpdateAvailableEvent&)>         onUpdateAvailable;
    std::function<void(const ConnectionStateEvent&)>        onConnectionState;

private:
    // -- Subprocess management -----------------------------------------------
    bool LaunchProcess();
    void TerminateProcess();

    // -- Pear runtime resolution ---------------------------------------------
    static std::string ResolvePearPath();

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

    // -- Stderr capture (Pear mode) ------------------------------------------
    void StderrReadLoop();
    std::thread stderrThread_;
    int stderrFd_ = -1;

    // -- Chunk reassembly ----------------------------------------------------
    struct ChunkBuffer {
        int                                   total = 0;
        uint64_t                              createdTick = 0;
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
    std::string pearKey_;
    WorkletLaunchMode launchMode_ = WorkletLaunchMode::Node;

    // -- Subprocess handles --------------------------------------------------
    pid_t childPid_      = -1;
    int   childIpcFd_    = -1;  // socketpair (Pear) or split below (Node)
    int   childStdinFd_  = -1;  // stdin pipe write end (Node fallback only)
    int   childStdoutFd_ = -1;  // stdout pipe read end (Node fallback only)
    int   listenFd_      = -1;  // UDS listen socket (Pear mode)
    std::string ipcSocketPath_;  // UDS path for Pear mode IPC

    // -- Threading -----------------------------------------------------------
    std::thread          readThread_;
    std::thread          writeThread_;
    std::mutex           writeMutex_;
    std::condition_variable writeCv_;
    std::atomic<bool>    running_{false};
    std::atomic<bool>    stopping_{false};
    void WriteLoop();

    // -- Write buffer / backpressure -----------------------------------------
    std::vector<uint8_t> pendingWrite_;
    uint64_t             droppedFrameCount_ = 0;

    static constexpr size_t kMaxPendingWriteBytes  = 8 * 1024 * 1024; // 8MB
    static constexpr size_t kMaxChunkPayload       = 65000;           // 65KB chunks (was 16KB)
    static constexpr size_t kMaxFrameLength        = 5 * 1024 * 1024;
    static constexpr int    kMaxChunksPerBuffer     = 256;
    static constexpr int    kMaxPendingChunkBuffers = 16;
    static constexpr uint64_t kChunkExpiryMs        = 2000; // 2s

    // -- Recv buffer ---------------------------------------------------------
    std::vector<uint8_t> recvBuf_;
    size_t               recvBufOffset_ = 0;

    // -- Helper: get read/write fds based on mode ----------------------------
    int ReadFd() const;
    int WriteFd() const;
};

} // namespace peariscope
