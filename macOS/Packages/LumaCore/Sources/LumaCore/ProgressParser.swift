import Foundation

/// Independent parser for FFmpeg -progress lines, usable by GUI and CLI.
public struct ProgressParser {
    private var seconds = 0.0
    private var fps: Double?

    public init() {}

    public mutating func accept(_ line: String, duration: Double) -> TranscodeProgress? {
        let pair = line.split(separator: "=", maxSplits: 1)
        guard pair.count == 2 else { return nil }
        switch pair[0] {
        case "fps":
            fps = Double(pair[1])
            return nil
        case "out_time_ms", "out_time_us":
            if let micros = Double(pair[1]) { seconds = max(0, micros / 1_000_000) }
            return TranscodeProgress(seconds: seconds, duration: duration, fps: fps)
        case "out_time":
            let parts = pair[1].split(separator: ":")
            if parts.count == 3,
               let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
                seconds = h * 3600 + m * 60 + s
                return TranscodeProgress(seconds: seconds, duration: duration, fps: fps)
            }
            return nil
        default: return nil
        }
    }
}
