import Foundation
import Synchronization

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

    /// Parses compact ffprobe side-data records with their original numeric
    /// values. This catches a later mastering-display change even if its
    /// side_data_type is identical to the first frame's SEI.
    static func staticMetadata(in line: String) -> HDRStaticMetadata? {
        var records: [String: [String: Any]] = [:]
        for field in line.split(separator: "|") {
            guard field.hasPrefix("side_datum/"),
                  let colon = field.firstIndex(of: ":") else { continue }
            let prefix = String(field[..<colon])
            guard prefix == "side_datum/mastering_display_metadata"
                || prefix == "side_datum/content_light_level_metadata" else { continue }
            let remainder = field[field.index(after: colon)...]
            guard let equal = remainder.firstIndex(of: "=") else { continue }
            let name = String(remainder[..<equal])
            let value = String(remainder[remainder.index(after: equal)...])
            records[prefix, default: [:]][name] = value
        }
        guard !records.isEmpty else { return nil }
        return HDRStaticMetadata.parse(Array(records.values))
    }

    static func verifyRecord(_ line: String, source: MediaInfo) throws {
        switch evidence(in: line) {
        case .none:
            return
        case .dynamicHDR:
            throw LumaError.unsupported(
                "HDR10+/Dolby Vision side data appears in a decoded frame. "
                + "This output would discard dynamic HDR metadata."
            )
        case .staticHDR:
            guard source.staticHDRMetadataPresent,
                  let expected = source.hdrStaticMetadata else {
                throw LumaError.unsupported(
                    "Static HDR10 data was not fully detected in the initial source probe."
                )
            }
            guard let detected = staticMetadata(in: line) else {
                throw LumaError.validationFailed(
                    "Full HDR scan found an incomplete or unparseable static SEI record."
                )
            }
            // A frame may expose only the mastering or only the content-light
            // message. Compare all present fields, preserving absent components.
            let expanded = HDRStaticMetadata(
                masteringDisplay: detected.masteringDisplay ?? expected.masteringDisplay,
                contentLight: detected.contentLight ?? expected.contentLight
            )
            guard expected.equivalent(to: expanded) else {
                throw LumaError.unsupported(
                    "HDR10 mastering or MaxCLL/MaxFALL values change after the initial "
                    + "probe. Per-frame static SEI preservation is not implemented."
                )
            }
        }
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
                    "frame=:frame_side_data=side_data_type,green_x,green_y,blue_x,blue_y,"
                    + "red_x,red_y,white_point_x,white_point_y,max_luminance,min_luminance,"
                    + "max_content,max_average",
                    "-of", "compact=p=1:nk=0", source.url.path
                ]
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stderrTail = Mutex(Data())
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
                        stderrTail.withLock { $0 = tail }
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
                            do {
                                try verifyRecord(line, source: source)
                            } catch {
                                checkError = error
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
                        do {
                            try verifyRecord(line, source: source)
                        } catch {
                            checkError = error
                        }
                    }
                    if checkError != nil && process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    stderrGroup.wait()
                    onProcess(nil)
                    if let checkError { throw checkError }
                    if isCancelled() { throw LumaError.cancelled }
                    guard process.terminationStatus == 0 else {
                        let message = stderrTail.withLock {
                            String(decoding: $0, as: UTF8.self)
                        }
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
