import Foundation
import Combine

public final class MemoryWatchdog: ObservableObject, @unchecked Sendable {

    public enum Pressure: Equatable {
        case normal
        case warning   // < 80MB available
        case critical  // < 40MB available
    }

    @Published public private(set) var pressure: Pressure = .normal

    private let warningThreshold: Int = 80    // MB
    private let criticalThreshold: Int = 40   // MB
    private let recoveryThreshold: Int = 120  // MB
    private var timer: Timer?
    private let interval: TimeInterval = 2.0

    public init() {}

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pressure = .normal
    }

    private func check() {
        #if os(iOS)
        let availableMB = Int(os_proc_available_memory() / 1_048_576)

        let newPressure: Pressure
        switch pressure {
        case .normal:
            if availableMB < criticalThreshold {
                newPressure = .critical
            } else if availableMB < warningThreshold {
                newPressure = .warning
            } else {
                newPressure = .normal
            }
        case .warning:
            if availableMB < criticalThreshold {
                newPressure = .critical
            } else if availableMB >= recoveryThreshold {
                newPressure = .normal
            } else {
                newPressure = .warning
            }
        case .critical:
            if availableMB >= recoveryThreshold {
                newPressure = .normal
            } else if availableMB >= warningThreshold {
                newPressure = .warning
            } else {
                newPressure = .critical
            }
        }

        if newPressure != pressure {
            NSLog("[memory] Pressure: %@ → %@ (available: %dMB)", "\(pressure)", "\(newPressure)", availableMB)
            DispatchQueue.main.async {
                self.pressure = newPressure
            }
        }
        #endif
    }
}
