import Foundation

/// A bounded full-decode preflight for codecs that may carry HDR10+ or Dolby
/// Vision metadata in frames beyond the few inspected by MediaProbe.
///
/// ffprobe emits one compact record per decoded display frame. We examine the
/// entire stream, never rely on an arbitrary read interval or FPS estimate,
/// and do not accumulate frame records in memory.
///
/// This prevents silent loss when FFmpeg exposes HDR10+/DOVI side data in
/// later frames. It is not a substitute for a future bitstream-level audit:
/// a decoder that hides proprietary RPU payloads cannot prove their absence.
public enum HDRSideDataSweep {
    private static let maxLineBytes = 64 * 1024

    public enum Evidence: Equatable, Sendable {
        case none
        case dynamicHDR(String)
        case staticHDR
    }

    public static func evidence(in line: String) -> Evidence {
        let value = line.lowercased()
        // The labels are ffprobe's side_data_type descriptions, not media
        // filenames or codec/profile names, which would create false matches.
        guard value.contains("side_data_type=") else { return .none }
        if value.contains("hdr10+") || value.contains("smpte2094-40")
            || value.contains("dovi") || value.contains("dolby vision") {
            return .dynamicHDR(line)
        }
        if value.contains("side_data_type=mastering display metadata")
            || value.contains("side_data_type=content light level metadata") {
            return .staticHDR
        }
        return .none
    }

    /// Fail closed for HDR-bearing codecs if the complete decoded scan fails.
    /// Cancellation terminates the ffprobe process as well as the encoder.
    public static func verifyBeforeEncoding(
        tools: MediaTools, source: MediaInfo,
        onProcess: @escaping @Sendable (Process?) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        guard ["hevc", "av1"].contains(source.codec) else { return }
        if source.dynamicHDR {
            throw LumaError.unsupported(
                "Source contains Dolby Vision or HDR10+; dynamic HDR preservation is not implemented."
            )
        }
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tools.ffprobe
                process.arguments = [
                    "-v", "error", "-select_streams", String(source.videoStreamIndex),
                    "-show_frames", "-show_entries",
                    "frame=:frame_side_data=side_data_type",
                    "-of", "compact=p=1:nk=0", source.url.path
                ]
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stderrTail = NSLock()
                var diagnostic = Data()
                let stderrGroup = DispatchGroup()
                do {
                    if isCancelled() { throw LumaError.cancelled }
                    try process.run()
                    onProcess(process)
                    stderrGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let file = stderr.fileHandleForReading
                        var tail = Data()
                        while true {
                            let next = file.readData(ofLength: 16 * 1024)
                            if next.isEmpty { break }
                            tail.append(next)
                            if tail.count > 32 * 1024 {
                                tail.removeFirst(tail.count - 32 * 1024)
                            }
                        }
                        stderrTail.lock()
                        diagnostic = tail
                        stderrTail.unlock()
                        stderrGroup.leave()
                    }

                    var pending = Data()
                    var scannedFrames = 0
                    var checkError: Error?
                    let file = stdout.fileHandleForReading
                    while checkError == nil {
                        if isCancelled() {
                            checkError = LumaError.cancelled
                            break
                        }
                        let next = file.readData(ofLength: 32 * 1024)
                        if next.isEmpty { break }
                        pending.append(next)
                        while let end = pending.firstIndex(of: 10) {
                            let lineData = pending.prefix(upTo: end)
                            pending.removeSubrange(...end)
                            guard lineData.count <= maxLineBytes else {
                                checkError = LumaError.validationFailed(
                                    "ffprobe HDR side-data record exceeds the safety limit."
                                )
                                break
                            }
                            let line = String(decoding: lineData, as: UTF8.self)
                            if line.hasPrefix("frame") { scannedFrames += 1 }
                            switch evidence(in: line) {
                            case .none: break
                            case .dynamicHDR:
                                checkError = LumaError.unsupported(
                                    "Dynamic HDR metadata was found in a later decoded frame. "
                                    + "Encoding would discard HDR10+/Dolby Vision metadata."
                                )
                            case .staticHDR where !source.staticHDRMetadataPresent:
                                checkError = LumaError.unsupported(
                                    "Static HDR10 metadata first appears after the initial source probe. "
                                    + "Its preservation has not been validated."
                                )
                            case .staticHDR: break
                            }
                            if checkError != nil { break }
                        }
                        if pending.count > maxLineBytes {
                            checkError = LumaError.validationFailed(
                                "ffprobe HDR side-data record exceeds the safety limit."
                            )
                        }
                    }
                    if checkError == nil && !pending.isEmpty {
                        let line = String(decoding: pending, as: UTF8.self)
                        if line.hasPrefix("frame") { scannedFrames += 1 }
                        switch evidence(in: line) {
                        case .none: break
                        case .dynamicHDR:
                            checkError = LumaError.unsupported(
                                "Unported dynamic HDR side data was detected."
                            )
                        case .staticHDR where !source.staticHDRMetadataPresent:
                            checkError = LumaError.unsupported(
                                "Unreported HDR10 mastering metadata was detected."
                            )
                        case .staticHDR: break
                        }
                    }
                    if checkError != nil && process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    stderrGroup.wait()
                    onProcess(nil)
                    if let checkError { throw checkError }
                    if isCancelled() { throw LumaError.cancelled }
                    guard process.terminationStatus == 0 else {
                        stderrTail.lock()
                        let message = String(decoding: diagnostic, as: UTF8.self)
                        stderrTail.unlock()
                        throw LumaError.processFailed(
                            "Could not audit all decoded HDR frames: \(message)"
                        )
                    }
                    guard scannedFrames > 0 else {
                        throw LumaError.validationFailed(
                            "Full HDR preflight did not decode any video frames."
                        )
                    }
                    continuation.resume()
                } catch {
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                    onProcess(nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
