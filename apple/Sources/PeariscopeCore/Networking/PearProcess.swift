import Foundation

#if os(macOS)
/// Manages the lifecycle of the Pear runtime child process.
public final class PearProcess: @unchecked Sendable {
    private var process: Process?
    private let pearDir: String
    private let socketPath: String

    public var onOutput: ((String) -> Void)?
    public var onTerminated: ((Int32) -> Void)?

    public init(
        pearDir: String = Bundle.main.bundlePath + "/Contents/Resources/pear",
        socketPath: String = "/tmp/peariscope.sock"
    ) {
        self.pearDir = pearDir
        self.socketPath = socketPath
    }

    /// Start the Pear runtime process
    public func start() throws {
        let proc = Process()

        // Priority: 1) bundled node, 2) pear CLI, 3) system node
        let bundledNode = Bundle.main.bundlePath + "/Contents/Resources/node"
        let pearPath: String
        if FileManager.default.isExecutableFile(atPath: bundledNode) {
            pearPath = bundledNode
        } else {
            pearPath = ProcessInfo.processInfo.environment["PEARISCOPE_PEAR_PATH"]
                ?? findPearBinary()
                ?? findNodeBinary()
                ?? "/usr/local/bin/node"
        }

        if pearPath.hasSuffix("pear") {
            proc.executableURL = URL(fileURLWithPath: pearPath)
            proc.arguments = ["run", pearDir]
        } else {
            proc.executableURL = URL(fileURLWithPath: pearPath)
            proc.arguments = [pearDir + "/index.js"]
        }

        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["PEARISCOPE_IPC_SOCKET"] = socketPath

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                self?.onOutput?(str)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            self?.onTerminated?(proc.terminationStatus)
        }

        try proc.run()
        self.process = proc
    }

    /// Stop the Pear runtime process
    public func stop() {
        process?.interrupt()
        process?.waitUntilExit()
        process = nil
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    private func findPearBinary() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/Library/Application Support/pear/bin/pear" },
            Optional("/usr/local/bin/pear"),
            Optional("/opt/homebrew/bin/pear"),
        ]
        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func findNodeBinary() -> String? {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.nvm/current/bin/node" },
        ]
        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
#endif
