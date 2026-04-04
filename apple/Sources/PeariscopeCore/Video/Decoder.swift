import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware-accelerated H.264 decoder using VideoToolbox.
/// Takes Annex B NAL units from the network and outputs CVPixelBuffers.
public final class H264Decoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let queue = DispatchQueue(label: "peariscope.decoder", qos: .userInteractive)

    /// Called with decoded pixel buffers ready for rendering
    public var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Optional log callback for diagnostics (fires from decoder serial queue)
    public var onLog: ((String) -> Void)?

    /// Whether the VT decompression session has been created (SPS+PPS received)
    public var hasSession: Bool { session != nil }

    // Stored SPS/PPS for creating format descriptions
    private var sps: Data?
    private var pps: Data?

    /// Limit queued blocks to prevent burst data from accumulating on the serial queue.
    private let pendingLock = NSLock()
    private var queuedBlocks: Int = 0
    #if os(iOS)
    private static let maxQueuedBlocks = 2
    #else
    private static let maxQueuedBlocks = 8  // macOS has plenty of memory
    #endif

    /// Time gate: drop frames arriving faster than display refresh.
    private var lastAcceptTime: CFAbsoluteTime = 0
    private static let minAcceptInterval: CFAbsoluteTime = 1.0 / 61.0 // ~60fps

    /// Track when queuedBlocks last hit max — reset if stuck too long
    private var queuedBlocksFullSince: CFAbsoluteTime = 0

    // Decode error tracking
    private var consecutiveDecodeErrors: Int = 0
    private var totalDecodeErrors: Int = 0

    // Diagnostics
    private var decodeCount: Int = 0
    private var uniqueBufferAddresses = Set<UInt>()

    public init() {}

    /// Force-recreate the VT session. Called when the viewer detects prolonged freeze.
    public func resetSession() {
        queue.async { [weak self] in
            guard let self else { return }
            NSLog("[h264] resetSession: forcing session recreation")
            self.consecutiveDecodeErrors = 0
            self.recreateSession()
            // Reset queuedBlocks in case it's stuck
            self.pendingLock.lock()
            self.queuedBlocks = 0
            self.queuedBlocksFullSince = 0
            self.pendingLock.unlock()
        }
    }

    /// Diagnostic summary — called from heartbeat.
    public func diagnosticSummary() -> String {
        return "decoded=\(decodeCount) uniqueBufs=\(uniqueBufferAddresses.count) errs(consecutive=\(consecutiveDecodeErrors) total=\(totalDecodeErrors))"
    }

    /// Feed Annex B formatted H.264 data from the network
    public func decode(annexBData: Data) {
        #if os(iOS)
        // Hard memory gate: drop ALL frames (including keyframes) when critically low.
        // Threshold must be well below typical available memory (~500-1500MB on most iPhones)
        // to avoid dropping frames during normal operation. The worklet termination at 400MB
        // provides a higher-level safety net.
        let availMB = os_proc_available_memory() / 1_048_576
        if availMB > 0 && availMB < 150 {
            NSLog("[h264-diag] MEMORY GATE: dropping frame, mem=\(availMB)MB len=\(annexBData.count)")
            return
        }
        #endif

        // Atomic time gate + queue depth check under lock.
        // The lock prevents races if BareKit fires readable callbacks from multiple threads.
        // No keyframe bypass — at 200+fps even keyframes cause OOM at 3440x1440.
        pendingLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAcceptTime < Self.minAcceptInterval {
            pendingLock.unlock()
            return
        }
        lastAcceptTime = now
        if queuedBlocks >= Self.maxQueuedBlocks {
            // If stuck at max for >2 seconds, the decode queue is probably blocked.
            // Reset the counter to unblock frame processing.
            if queuedBlocksFullSince == 0 {
                queuedBlocksFullSince = now
            } else if now - queuedBlocksFullSince > 2.0 {
                NSLog("[h264] queuedBlocks stuck at %d for >2s, resetting", queuedBlocks)
                queuedBlocks = 0
                queuedBlocksFullSince = 0
            } else {
                pendingLock.unlock()
                return
            }
        } else {
            queuedBlocksFullSince = 0
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

    private func _decode(annexBData: Data) {
        let nalUnits = parseAnnexB(annexBData)

        if decodeCount == 0 && nalUnits.isEmpty {
            NSLog("[h264-diag] FIRST FRAME: no NAL units found in %d bytes — not Annex B?", annexBData.count)
            if annexBData.count >= 8 {
                let header = annexBData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                NSLog("[h264-diag] FIRST FRAME header: %@", header)
            }
        }

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F

            if decodeCount == 0 {
                NSLog("[h264-diag] NAL type=%d size=%d hasSession=%@ hasSPS=%@ hasPPS=%@",
                      nalType, nal.count, session != nil ? "yes" : "no",
                      sps != nil ? "yes" : "no", pps != nil ? "yes" : "no")
            }

            switch nalType {
            case 7: // SPS
                sps = nal
                NSLog("[h264] Got SPS (%d bytes)", nal.count)
            case 8: // PPS
                pps = nal
                NSLog("[h264] Got PPS (%d bytes)", nal.count)
                if sps != nil {
                    updateFormatDescription()
                }
            case 1, 5: // Non-IDR slice, IDR slice
                if nalType == 5 {
                    NSLog("[h264] IDR (%d bytes), session=%@", nal.count, session != nil ? "yes" : "no")
                    // Recreate session on IDR if previous decodes were failing.
                    // VT sessions can enter an unrecoverable error state after
                    // corrupt frames — a fresh session + IDR resets everything.
                    if consecutiveDecodeErrors > 3 {
                        NSLog("[h264] Recreating session after %d consecutive errors", consecutiveDecodeErrors)
                        consecutiveDecodeErrors = 0
                        recreateSession()
                    }
                }
                decodeNALUnit(nal)
            default:
                NSLog("[h264-diag] Unknown NAL type=%d size=%d", nalType, nal.count)
                break
            }
        }
    }

    private func updateFormatDescription() {
        guard let sps, let pps else { return }

        let spsBytes = Array(sps)
        let ppsBytes = Array(pps)
        let sizes: [Int] = [spsBytes.count, ppsBytes.count]

        var newFormatDesc: CMVideoFormatDescription?
        let status = spsBytes.withUnsafeBufferPointer { spsPtr in
            ppsBytes.withUnsafeBufferPointer { ppsPtr in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!,
                    ppsPtr.baseAddress!
                ]
                return pointers.withUnsafeBufferPointer { ptrs in
                    sizes.withUnsafeBufferPointer { szs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: szs.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormatDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let newFormatDesc else { return }

        if formatDescription == nil || !CMFormatDescriptionEqual(formatDescription!, otherFormatDescription: newFormatDesc) {
            formatDescription = newFormatDesc
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

        guard status == noErr else { return }
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

        var infoFlags = VTDecodeInfoFlags()
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags,
            outputHandler: { [weak self] status, _, imageBuffer, pts, _ in
                guard status == noErr, let imageBuffer else {
                    if status != noErr {
                        self?.consecutiveDecodeErrors += 1
                        self?.totalDecodeErrors += 1
                    }
                    return
                }
                self?.consecutiveDecodeErrors = 0
                self?.decodeCount += 1
                self?.onDecodedFrame?(imageBuffer, pts)
            }
        )

        if decodeStatus != noErr {
            consecutiveDecodeErrors += 1
            totalDecodeErrors += 1
            NSLog("[h264] DecodeFrame error: %d (consecutive: %d)", decodeStatus, consecutiveDecodeErrors)
            return
        }

        // Wait for decode to complete. This prevents unbounded pixel buffer pool growth.
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        let elapsed = CFAbsoluteTimeGetCurrent() - decodeStart
        if elapsed > 0.5 {
            NSLog("[h264] SLOW decode: %.1fms — recreating session", elapsed * 1000)
            recreateSession()
        }
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
        queue.sync {
            if let session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            self.onDecodedFrame = nil
            formatDescription = nil
            sps = nil
            pps = nil
        }
    }
}
