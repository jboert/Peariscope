import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware-accelerated H.265/HEVC decoder using VideoToolbox.
/// Takes Annex B NAL units from the network and outputs CVPixelBuffers.
public final class H265Decoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let queue = DispatchQueue(label: "peariscope.h265decoder", qos: .userInteractive)

    public var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Fired (at most once) when consecutive decode errors exceed threshold — viewer should request H.264 fallback
    public var onCodecFallbackNeeded: (() -> Void)?

    // HEVC parameter sets
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?

    /// Flush all queued decode blocks without destroying the session.
    public func flushQueue() {
        pendingLock.lock()
        queuedBlocks = 0
        pendingLock.unlock()
        NSLog("[h265] Frame queue flushed")
    }

    /// Force-recreate the VT session. Called when the viewer detects prolonged freeze.
    public func resetSession() {
        queue.async { [weak self] in
            guard let self else { return }
            NSLog("[h265] resetSession: forcing session recreation")
            self.recreateSession()
            self.pendingLock.lock()
            self.queuedBlocks = 0
            self.pendingLock.unlock()
        }
    }

    /// Limit queued blocks to prevent burst data from accumulating on the serial queue.
    private let pendingLock = NSLock()
    private var queuedBlocks: Int = 0
    private static let maxQueuedBlocks = 2

    /// Time gate: drop frames arriving faster than display refresh to prevent VT
    /// from allocating hundreds of pixel buffers during network burst delivery.
    private var lastAcceptTime: CFAbsoluteTime = 0
    private static let minAcceptInterval: CFAbsoluteTime = 1.0 / 61.0 // ~60fps

    // Decode error tracking for codec fallback
    private var consecutiveDecodeErrors: Int = 0
    private var totalDecodeErrors: Int = 0
    private var fallbackRequested: Bool = false

    // Diagnostics: track VT pool behavior
    private var decodeCount: Int = 0
    private var uniqueBufferAddresses = Set<UInt>()
    private var timeGateDrops: Int = 0
    private var queueFullDrops: Int = 0
    private var memoryGateDrops: Int = 0
    private var callerThreads = Set<String>()
    private var decodeEntryCount: Int = 0

    public init() {}

    public func decode(annexBData: Data) {
        // Track which threads call decode() — BareKit may use multiple threads
        decodeEntryCount += 1
        let threadName = "\(Thread.current)"
        if callerThreads.insert(threadName).inserted {
            NSLog("[h265-diag] decode() called from NEW thread: %@ (total unique threads: %d, entry #%d)",
                  threadName, callerThreads.count, decodeEntryCount)
        }

        #if os(iOS)
        // Hard memory gate: drop ALL frames (including keyframes) when critically low.
        // Threshold must be well below typical available memory (~500-1500MB on most iPhones)
        // to avoid dropping frames during normal operation. The worklet termination at 400MB
        // provides a higher-level safety net.
        let availMB = os_proc_available_memory() / 1_048_576
        if availMB > 0 && availMB < 150 {
            memoryGateDrops += 1
            if memoryGateDrops <= 10 || memoryGateDrops % 100 == 0 {
                NSLog("[h265-diag] MEMORY GATE DROP: mem=%dMB drops=%d", availMB, memoryGateDrops)
            }
            return
        }
        #endif

        // Atomic time gate + queue depth check under lock.
        // The lock prevents races if BareKit fires readable callbacks from multiple threads.
        // No keyframe bypass — at 200+fps even keyframes cause OOM at 3440x1440.
        pendingLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAcceptTime < Self.minAcceptInterval {
            timeGateDrops += 1
            pendingLock.unlock()
            return
        }
        lastAcceptTime = now
        if queuedBlocks >= Self.maxQueuedBlocks {
            queueFullDrops += 1
            pendingLock.unlock()
            return
        }
        queuedBlocks += 1
        pendingLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self._decode(annexBData: annexBData)
            // Decrement AFTER decode completes (not before) so that the queue depth
            // limit actually restricts throughput. With synchronous VT decode (~5ms),
            // max 3 queued blocks = max ~60fps throughput.
            self.pendingLock.lock()
            self.queuedBlocks -= 1
            self.pendingLock.unlock()
        }
    }

    /// Diagnostic summary — called from heartbeat to get decoder stats without extra logging overhead.
    public func diagnosticSummary() -> String {
        #if os(iOS)
        let availMB = os_proc_available_memory() / 1_048_576
        #else
        let availMB: UInt64 = 0
        #endif
        pendingLock.lock()
        let queued = queuedBlocks
        pendingLock.unlock()
        return "decoded=\(decodeCount) uniqueBufs=\(uniqueBufferAddresses.count) queued=\(queued) entries=\(decodeEntryCount) threads=\(callerThreads.count) drops(time=\(timeGateDrops) queue=\(queueFullDrops) mem=\(memoryGateDrops)) errs(consecutive=\(consecutiveDecodeErrors) total=\(totalDecodeErrors)) mem=\(availMB)MB"
    }

    private func _decode(annexBData: Data) {
        let nalUnits = parseAnnexB(annexBData)

        for nal in nalUnits {
            guard nal.count >= 2 else { continue }
            let nalType = (nal[0] >> 1) & 0x3F

            switch nalType {
            case 32: // VPS
                vps = nal
                NSLog("[h265] Got VPS (%d bytes)", nal.count)
            case 33: // SPS
                sps = nal
                NSLog("[h265] Got SPS (%d bytes)", nal.count)
            case 34: // PPS
                pps = nal
                NSLog("[h265] Got PPS (%d bytes)", nal.count)
                if vps != nil && sps != nil {
                    updateFormatDescription()
                }
            case 0...9, 16...21:
                let isIDR = nalType >= 16 && nalType <= 21
                if isIDR { NSLog("[h265] IDR (%d bytes), session=%@", nal.count, session != nil ? "yes" : "no") }
                decodeNALUnit(nal)
            default:
                break
            }
        }
    }

    private func updateFormatDescription() {
        guard let vps, let sps, let pps else { return }

        let vpsBytes = Array(vps)
        let spsBytes = Array(sps)
        let ppsBytes = Array(pps)
        let sizes: [Int] = [vpsBytes.count, spsBytes.count, ppsBytes.count]

        var newFormatDesc: CMVideoFormatDescription?
        let status = vpsBytes.withUnsafeBufferPointer { vpsPtr in
            spsBytes.withUnsafeBufferPointer { spsPtr in
                ppsBytes.withUnsafeBufferPointer { ppsPtr in
                    let pointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!,
                        spsPtr.baseAddress!,
                        ppsPtr.baseAddress!
                    ]
                    return pointers.withUnsafeBufferPointer { ptrs in
                        sizes.withUnsafeBufferPointer { szs in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: ptrs.baseAddress!,
                                parameterSetSizes: szs.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &newFormatDesc
                            )
                        }
                    }
                }
            }
        }

        guard status == noErr, let newFormatDesc else {
            NSLog("[h265] Failed to create format description: %d", status)
            return
        }

        if formatDescription == nil || !CMFormatDescriptionEqual(formatDescription!, otherFormatDescription: newFormatDesc) {
            formatDescription = newFormatDesc
            NSLog("[h265] Format description created, recreating session")
            recreateSession()
        }
    }

    private func recreateSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        guard let formatDescription else { return }

        let destAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr else {
            NSLog("[h265] Failed to create decompression session: %d", status)
            consecutiveDecodeErrors += 1
            totalDecodeErrors += 1
            if consecutiveDecodeErrors >= 5 && !fallbackRequested {
                fallbackRequested = true
                NSLog("[h265] Session creation failing, requesting codec fallback")
                onCodecFallbackNeeded?()
            }
            return
        }
        NSLog("[h265] Decompression session created")
        self.session = session

        if let session {
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
    }

    private func decodeNALUnit(_ nalData: Data) {
        guard let session, let formatDescription else { return }

        let avccLength = 4 + nalData.count
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let blockBuffer else { return }

        var length = UInt32(nalData.count).bigEndian
        _ = withUnsafeBytes(of: &length) { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: 4
            )
        }

        _ = nalData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 4,
                dataLength: nalData.count
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccLength
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else { return }

        // Synchronous decode: blocks until VT returns the pixel buffer.
        // flags: [] (no ._EnableAsynchronousDecompression) requests synchronous,
        // but iOS hardware decoders may still decode asynchronously.
        // WaitForAsynchronousFrames after each decode ENFORCES synchronous behavior,
        // keeping VT's pixel buffer pool to 1-2 buffers and preventing the
        // multi-GB memory spike from unbounded async pool growth.
        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags,
            outputHandler: { [weak self] status, _, imageBuffer, pts, _ in
                guard status == noErr, let imageBuffer else {
                    if status != noErr {
                        self?.consecutiveDecodeErrors += 1
                        self?.totalDecodeErrors += 1
                        let consecutive = self?.consecutiveDecodeErrors ?? 0
                        let total = self?.totalDecodeErrors ?? 0
                        NSLog("[h265-diag] VT decode error: %d (consecutive=%d total=%d)", status, consecutive, total)
                        if consecutive >= 5, self?.fallbackRequested == false {
                            self?.fallbackRequested = true
                            NSLog("[h265] Consecutive decode errors >= 5, requesting codec fallback")
                            self?.onCodecFallbackNeeded?()
                        }
                        let badDataErr: OSStatus = -12909  // kVTVideoDecoderBadDataErr
                        let sessionInvalid: OSStatus = -12903  // kVTInvalidSessionErr
                        if status == badDataErr || status == sessionInvalid {
                            NSLog("[h265] Unrecoverable VT error %d — recreating session", status)
                            self?.recreateSession()
                        }
                    }
                    return
                }
                self?.consecutiveDecodeErrors = 0
                // Track unique pixel buffer addresses to detect pool growth
                let addr = UInt(bitPattern: Unmanaged.passUnretained(imageBuffer).toOpaque())
                self?.uniqueBufferAddresses.insert(addr)
                self?.decodeCount += 1
                self?.onDecodedFrame?(imageBuffer, pts)
            }
        )
        // Force-wait for any async decode to complete before returning.
        // Without this, VT on iOS allocates a new pool buffer per frame (~7.4MB at 3440x1440),
        // consuming ~2.7GB in seconds at 60fps.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    /// Parse Annex B byte stream into individual NAL units (without start codes).
    private func parseAnnexB(_ data: Data) -> [Data] {
        data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> [Data] in
            guard let bytes = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let count = rawBuf.count
            var nalUnits: [Data] = []
            var i = 0

            while i < count {
                var startCodeLen = 0
                if i + 3 < count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                    startCodeLen = 4
                } else if i + 2 < count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                    startCodeLen = 3
                }

                if startCodeLen > 0 {
                    let nalStart = i + startCodeLen
                    var nalEnd = count
                    for j in nalStart..<count {
                        if j + 3 < count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                            nalEnd = j; break
                        }
                        if j + 2 < count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 1 {
                            nalEnd = j; break
                        }
                    }
                    if nalEnd > nalStart {
                        nalUnits.append(Data(bytes: bytes + nalStart, count: nalEnd - nalStart))
                    }
                    i = nalEnd
                } else {
                    i += 1
                }
            }
            return nalUnits
        }
    }

    public func stop() {
        // Nil callbacks immediately to stop delivering decoded frames.
        // This is safe from any thread — the decoder checks these before calling.
        onDecodedFrame = nil
        onCodecFallbackNeeded = nil
        // Tear down VT session asynchronously on the decoder queue.
        // NEVER use queue.sync here — the queue may be blocked in
        // VTDecompressionSessionDecodeFrame/WaitForAsynchronousFrames,
        // and sync from the main thread deadlocks (0x8BADF00D watchdog kill).
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            self.formatDescription = nil
            self.vps = nil
            self.sps = nil
            self.pps = nil
            self.consecutiveDecodeErrors = 0
            self.totalDecodeErrors = 0
            self.fallbackRequested = false
        }
    }
}
