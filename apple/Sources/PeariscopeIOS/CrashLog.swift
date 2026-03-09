#if os(iOS)
import Foundation

/// Persistent crash log — survives app termination so we can read it on next launch.
/// Writes to Documents/peariscope-crash.log.
enum CrashLog {
    nonisolated(unsafe) static var fileHandle: FileHandle?
    nonisolated(unsafe) static var logPath: String = ""
    /// Stash the previous session's log so it survives setup() truncation
    nonisolated(unsafe) static var previousLog: String?

    static func setup() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        logPath = (docs as NSString).appendingPathComponent("peariscope-crash.log")

        // Read the PREVIOUS session's log before we overwrite the file
        previousLog = try? String(contentsOfFile: logPath, encoding: .utf8)

        // Now truncate and start fresh for this session
        FileManager.default.createFile(atPath: logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: logPath)
        write("=== App launched at \(Date()) ===")
        write("Available memory: \(os_proc_available_memory() / 1_048_576) MB")
    }

    static func write(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        fileHandle?.write(line.data(using: .utf8) ?? Data())
        fileHandle?.synchronizeFile()
        NSLog("[crash-log] %@", msg)
    }

    /// Get the previous session's log (captured before setup() truncated the file)
    static func readPrevious() -> String? {
        previousLog
    }

    /// Read the current session's log
    static func read() -> String? {
        guard !logPath.isEmpty else { return nil }
        return try? String(contentsOfFile: logPath, encoding: .utf8)
    }
}
#endif
