import Foundation
import Network

/// Advertises a Peariscope host on the local network via Bonjour.
/// Used by the Mac host to make its connection code discoverable by iOS viewers.
@MainActor
public final class LocalDiscoveryAdvertiser: ObservableObject {
    private var listener: NWListener?
    private var connectionCode: String?
    private var hostName: String?
    @Published public var isAdvertising = false

    public init() {}

    public func start(code: String, name: String, publicKeyHex: String? = nil, dhtPort: UInt16 = 0) {
        stop()
        connectionCode = code
        hostName = name

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params)

            // Advertise as _peariscope._tcp with connection code + peer identity in TXT record.
            // publicKeyHex and dhtPort let LAN viewers inject our local address into
            // the DHT for sub-second connections instead of going through remote bootstrap.
            var txtDict: [String: String] = ["code": code, "name": name]
            if let pk = publicKeyHex, !pk.isEmpty {
                txtDict["pk"] = pk
            }
            if dhtPort > 0 {
                txtDict["dhtPort"] = "\(dhtPort)"
            }
            let txtData = NetService.data(fromTXTRecord: txtDict.mapValues { Data($0.utf8) })
            let txtRecord = NWTXTRecord(txtData)
            listener.service = NWListener.Service(
                name: name,
                type: "_peariscope._tcp",
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isAdvertising = true
                        NSLog("[bonjour] Advertising: %@ (code: %@...)", name, String(code.prefix(20)))
                    case .failed(let error):
                        NSLog("[bonjour] Advertiser failed: %@", error.localizedDescription)
                        self?.isAdvertising = false
                    case .cancelled:
                        self?.isAdvertising = false
                    default:
                        break
                    }
                }
            }

            // Accept connections but immediately cancel — we only use Bonjour for discovery,
            // not for data transfer. The actual connection goes through Hyperswarm.
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("[bonjour] Failed to create listener: %@", error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
    }

    /// Update the advertised connection code (e.g., after regenerating)
    public func updateCode(_ code: String, publicKeyHex: String? = nil, dhtPort: UInt16 = 0) {
        guard let name = hostName else { return }
        start(code: code, name: name, publicKeyHex: publicKeyHex, dhtPort: dhtPort)
    }
}

/// Discovered Peariscope host on the local network
public struct DiscoveredHost: Identifiable, Equatable {
    public let id: String  // endpoint description
    public let name: String
    public let code: String
    public let publicKeyHex: String?
    public let dhtPort: UInt16
    /// The Bonjour browse result endpoint — resolved to get the host's local IP
    public let endpoint: NWEndpoint?
    public let discoveredAt: Date

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.id == rhs.id && lhs.code == rhs.code
    }
}

/// Browses for Peariscope hosts on the local network via Bonjour.
/// Used by iOS viewers to discover nearby hosts without manual code entry.
@MainActor
public final class LocalDiscoveryBrowser: ObservableObject {
    private var browser: NWBrowser?
    @Published public var discoveredHosts: [DiscoveredHost] = []
    @Published public var isBrowsing = false

    public init() {}

    public func start() {
        stop()

        let params = NWBrowser.Descriptor.bonjour(type: "_peariscope._tcp", domain: nil)
        let browser = NWBrowser(for: params, using: .tcp)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                    NSLog("[bonjour] Browsing for Peariscope hosts...")
                case .failed(let error):
                    NSLog("[bonjour] Browser failed: %@", error.localizedDescription)
                    self?.isBrowsing = false
                case .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        discoveredHosts.removeAll()
        isBrowsing = false
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var hosts: [DiscoveredHost] = []

        for result in results {
            guard case .service(let name, let type, _, _) = result.endpoint else { continue }
            guard type == "_peariscope._tcp." else { continue }

            // Extract TXT record metadata
            if case .bonjour(let txtRecord) = result.metadata {
                let txtDict = Self.parseTXTRecord(txtRecord)
                let code = txtDict["code"] ?? ""
                let displayName = txtDict["name"] ?? name
                let publicKeyHex = txtDict["pk"]
                let dhtPort = UInt16(txtDict["dhtPort"] ?? "") ?? 0

                if !code.isEmpty {
                    let host = DiscoveredHost(
                        id: "\(name).\(type)",
                        name: displayName,
                        code: code,
                        publicKeyHex: publicKeyHex,
                        dhtPort: dhtPort,
                        endpoint: result.endpoint,
                        discoveredAt: Date()
                    )
                    hosts.append(host)
                }
            }
        }

        discoveredHosts = hosts
        if !hosts.isEmpty {
            NSLog("[bonjour] Found %d host(s): %@", hosts.count, hosts.map { $0.name }.joined(separator: ", "))
        }
    }
}

// MARK: - Endpoint Resolution

extension LocalDiscoveryBrowser {
    /// Resolve a Bonjour endpoint to an IPv4 address string.
    /// Uses NWConnection to trigger resolution, then extracts the IP from the resolved path.
    public static func resolveEndpoint(_ endpoint: NWEndpoint, timeout: TimeInterval = 3.0) async -> String? {
        // Use a class to safely share mutable state across sendable closures
        final class ResolveState: @unchecked Sendable {
            private let lock = NSLock()
            private var _resumed = false
            var resumed: Bool {
                get { lock.withLock { _resumed } }
                set { lock.withLock { _resumed = newValue } }
            }
        }
        let state = ResolveState()

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)

            connection.stateUpdateHandler = { newState in
                guard !state.resumed else { return }
                switch newState {
                case .ready:
                    state.resumed = true
                    // Extract IP from the resolved remote endpoint
                    if let path = connection.currentPath,
                       let remoteEndpoint = path.remoteEndpoint,
                       case .hostPort(let host, _) = remoteEndpoint {
                        let ip: String?
                        switch host {
                        case .ipv4(let addr):
                            ip = "\(addr)"
                        case .ipv6(let addr):
                            let s = "\(addr)"
                            // Skip link-local IPv6
                            ip = s.hasPrefix("fe80") ? nil : s
                        default:
                            ip = nil
                        }
                        connection.cancel()
                        continuation.resume(returning: ip)
                    } else {
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                case .failed, .cancelled:
                    state.resumed = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            // Timeout fallback
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !state.resumed else { return }
                state.resumed = true
                connection.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: - TXT Record Helpers

extension LocalDiscoveryBrowser {
    /// Parse NWTXTRecord into a string dictionary using NetService
    /// Parse NWTXTRecord into a string dictionary
    nonisolated static func parseTXTRecord(_ txtRecord: NWTXTRecord) -> [String: String] {
        // NWTXTRecord conforms to Collection of (key, value) entries
        var result: [String: String] = [:]
        for (key, value) in txtRecord.dictionary {
            result[key] = value
        }
        return result
    }
}
