import Foundation
import CoreImage

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Handles QR code generation and parsing for device pairing.
public final class QRPairing: Sendable {
    public init() {}

    // MARK: - QR Code Generation

    /// Generate a QR code image from a Peariscope pairing URI
    public func generateQRCode(connectionCode: String, publicKey: Data) -> CGImage? {
        let pairingURI = encodePairingURI(connectionCode: connectionCode, publicKey: publicKey)
        return generateQRImage(from: pairingURI)
    }

    /// Generate a CGImage QR code from any string
    public func generateQRImage(from string: String, size: CGFloat = 300) -> CGImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter?.outputImage else { return nil }

        let scale = size / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }

    // MARK: - Pairing URI

    /// Encode pairing information into a URI for QR codes
    public func encodePairingURI(connectionCode: String, publicKey: Data, token: Data? = nil) -> String {
        let payload: [String: Any] = [
            "v": 1,
            "k": publicKey.map { String(format: "%02x", $0) }.joined(),
            "c": connectionCode,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return "peariscope://\(connectionCode)"
        }

        let encoded = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return "peariscope://\(encoded)"
    }

    /// Decode a pairing URI back into components
    public func decodePairingURI(_ uri: String) -> (connectionCode: String, publicKey: Data)? {
        guard uri.hasPrefix("peariscope://") else { return nil }
        let encoded = String(uri.dropFirst("peariscope://".count))

        // Add back base64 padding
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let jsonData = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let code = payload["c"] as? String,
              let keyHex = payload["k"] as? String else {
            // Fallback: treat the encoded part as a raw connection code
            return (connectionCode: encoded, publicKey: Data())
        }

        // Convert hex string to Data
        var keyData = Data()
        var hex = keyHex
        while hex.count >= 2 {
            let byte = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let b = UInt8(byte, radix: 16) {
                keyData.append(b)
            }
        }

        return (connectionCode: code, publicKey: keyData)
    }
}
