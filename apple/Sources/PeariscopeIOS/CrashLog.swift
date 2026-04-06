#if os(iOS)
import Foundation

/// Persistent crash log — survives app termination so we can read it on next launch.
/// Writes to Documents/peariscope-crash.log as JSONL (one JSON object per line).
enum CrashLog {
    nonisolated(unsafe) static var fileHandle: FileHandle?
    nonisolated(unsafe) static var logPath: String = ""
    /// Stash the previous session's log so it survives setup() truncation
    nonisolated(unsafe) static var previousLog: String?
    nonisolated(unsafe) static var previousSessionCrashed = false
    nonisolated(unsafe) static var previousSessionPeakMem = 0

    enum LogLevel: String {
        case info = "info"
        case warn = "warn"
        case error = "error"
        case fatal = "fatal"
    }

    static func setup() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        logPath = (docs as NSString).appendingPathComponent("peariscope-crash.log")

        // Read the PREVIOUS session's log before we overwrite the file
        previousLog = try? String(contentsOfFile: logPath, encoding: .utf8)

        // Detect unclean shutdown: if the previous log has no clean exit marker,
        // the app was likely killed by jetsam or crashed.
        if let prev = previousLog, !prev.isEmpty {
            let hadCleanExit = prev.contains("\"msg\":\"App entering background\"") ||
                               prev.contains("\"msg\":\"App terminating\"") ||
                               prev.contains("\"msg\":\"User disconnected\"")
            if !hadCleanExit {
                var peakMem = 0
                for line in prev.components(separatedBy: "\n") where line.contains("mem_mb") {
                    if let range = line.range(of: "\"mem_mb\":"),
                       let end = line[range.upperBound...].firstIndex(where: { !$0.isNumber }),
                       let mem = Int(line[range.upperBound..<end]) {
                        peakMem = max(peakMem, mem)
                    }
                }
                previousSessionCrashed = true
                previousSessionPeakMem = peakMem
            }
        }

        // Now truncate and start fresh for this session
        FileManager.default.createFile(atPath: logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: logPath)
        write("App launched", level: .info)
        write("Memory check", level: .info, extra: ["startup": true])
    }

    /// Write a structured JSONL log entry.
    /// Uses manual string interpolation to avoid Foundation allocations on crash paths.
    static func write(_ msg: String, level: LogLevel = .info, extra: [String: Any]? = nil) {
        let ts = iso8601Timestamp()
        let memMB = os_proc_available_memory() / 1_048_576
        let escapedMsg = jsonEscape(msg)

        var line = "{\"ts\":\"\(ts)\",\"level\":\"\(level.rawValue)\",\"msg\":\"\(escapedMsg)\",\"mem_mb\":\(memMB)"

        if let extra = extra {
            for (key, value) in extra {
                let escapedKey = jsonEscape(key)
                switch value {
                case let v as String:
                    line += ",\"\(escapedKey)\":\"\(jsonEscape(v))\""
                case let v as Bool:
                    line += ",\"\(escapedKey)\":\(v ? "true" : "false")"
                case let v as Int:
                    line += ",\"\(escapedKey)\":\(v)"
                case let v as Int64:
                    line += ",\"\(escapedKey)\":\(v)"
                case let v as UInt64:
                    line += ",\"\(escapedKey)\":\(v)"
                case let v as Double:
                    line += ",\"\(escapedKey)\":\(v)"
                case let v as Float:
                    line += ",\"\(escapedKey)\":\(v)"
                default:
                    line += ",\"\(escapedKey)\":\"\(jsonEscape(String(describing: value)))\""
                }
            }
        }

        line += "}\n"
        fileHandle?.write(line.data(using: .utf8) ?? Data())
        fileHandle?.synchronizeFile()
        NSLog("[crash-log] %@", msg)
    }

    // MARK: - Convenience methods

    static func warn(_ msg: String, extra: [String: Any]? = nil) {
        write(msg, level: .warn, extra: extra)
    }

    static func error(_ msg: String, extra: [String: Any]? = nil) {
        write(msg, level: .error, extra: extra)
    }

    static func fatal(_ msg: String, extra: [String: Any]? = nil) {
        write(msg, level: .fatal, extra: extra)
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

    // MARK: - Private helpers

    /// Generate ISO8601 timestamp with milliseconds.
    /// Uses timeIntervalSince1970 to avoid DateFormatter allocations in signal handlers.
    private static func iso8601Timestamp() -> String {
        let now = Date()
        let ti = now.timeIntervalSince1970
        let seconds = Int(ti)
        let millis = Int((ti - Double(seconds)) * 1000)

        // Build UTC timestamp manually to avoid allocations
        var t = tm()
        var time = time_t(seconds)
        gmtime_r(&time, &t)

        let year = Int(t.tm_year) + 1900
        let month = Int(t.tm_mon) + 1
        let day = Int(t.tm_mday)
        let hour = Int(t.tm_hour)
        let min = Int(t.tm_min)
        let sec = Int(t.tm_sec)

        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                       year, month, day, hour, min, sec, millis)
    }

    /// Escape a string for safe JSON embedding.
    /// Handles backslash, double quote, and control characters.
    private static func jsonEscape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(c)
            }
        }
        return result
    }
}
#endif
