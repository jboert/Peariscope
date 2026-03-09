import Foundation

public enum PeerFingerprint {
    /// Convert a hex public key to a human-readable fingerprint
    /// Input: "a3f2b1c8d9e4f7a2..." (64 char hex)
    /// Output: "A3F2:B1C8:D9E4:F7A2"
    public static func format(_ hexKey: String) -> String {
        let upper = hexKey.uppercased()
        let chars = Array(upper.prefix(16))
        guard chars.count >= 16 else { return String(upper.prefix(16)) }
        return stride(from: 0, to: 16, by: 4).map { i in
            String(chars[i..<min(i+4, chars.count)])
        }.joined(separator: ":")
    }
}
