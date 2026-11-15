import Foundation

/// Bounded ffprobe timeline loader. Mirrors Windows FrameTimeline packet-first
/// strategy, falling back to decoded frames when packet PTS are unreliable.
public enum FrameTimelineLoader {
    private static let packetCodecs: Set<String> = [
        "h264", "hevc", "prores", "prores_raw", "mjpeg", "dnxhd"
    ]
    private static let maxIndexBytes = 64 * 1024 * 1024
    private static let maxFrames = 2_000_000

    public static func load(tools: MediaTools, media: MediaInfo) async throws -> FrameTimeline {
        let parts = media.timeBase.split(separator: "/")
        guard parts.count == 2,
              let numerator = Int64(parts[0]), let denominator = Int64(parts[1]),
              numerator > 0, denominator > 0 else {
            throw LumaError.invalidInput("ffprobe did not return a usable video time_base.")
        }

        if !media.isInterlaced && packetCodecs.contains(media.codec) {
            if let packets = try? await read(tools: tools, media: media, packets: true),
               !packets.isEmpty {
                let sorted = packets.sorted { $0.pts < $1.pts }
                let unique = zip(sorted, sorted.dropFirst()).allSatisfy {
                    $0.pts != $1.pts
                }
                if unique {
                    return try FrameTimeline(
                        frames: sorted, numerator: numerator,
                        denominator: denominator, packetIndexed: true
                    )
                }
            }
        }

        guard let frames = try await read(tools: tools, media: media, packets: false),
              !frames.isEmpty else {
            throw LumaError.invalidInput("Could not build a decoded frame timeline.")
        }
        return try FrameTimeline(
            frames: frames, numerator: numerator,
            denominator: denominator, packetIndexed: false
        )
    }

    /// nil indicates a missing/duplicate timestamp or invalid packet record.
    static func parseCompact(_ text: String, packets: Bool) -> [FramePoint]? {
        var result: [FramePoint] = []
        let prefix = packets ? "packet|" : "frame|"
        for line in text.split(separator: "\n") {
            guard line.hasPrefix(prefix) else { continue }
            var pts: Int64?
            var duration: Int64 = 0
            var keyFrame = false
            var discarded = false
            for part in line.split(separator: "|").dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case packets ? "pts" : "best_effort_timestamp":
                    pts = Int64(pair[1])
                case "duration":
                    duration = Int64(pair[1]) ?? 0
                case "flags" where packets:
                    discarded = pair[1].contains("D")
                    keyFrame = pair[1].contains("K")
                case "key_frame" where !packets:
                    keyFrame = pair[1] == "1"
                default: break
                }
            }
            if discarded { continue }
            guard let pts else { return nil }
            result.append(FramePoint(pts: pts, duration: duration, keyFrame: keyFrame))
            if result.count > maxFrames { return nil }
        }
        return result
    }

    private static func read(
        tools: MediaTools, media: MediaInfo, packets: Bool
    ) async throws -> [FramePoint]? {
        let type = packets ? "packet" : "frame"
        let fields = packets
            ? "packet=pts,duration,flags:packet_side_data="
            : "frame=best_effort_timestamp,duration,key_frame:frame_side_data="
        let result = try await CommandCapture.run(
            tools.ffprobe,
            ["-v", "error", "-threads", "2",
             "-select_streams", String(media.videoStreamIndex),
             packets ? "-show_packets" : "-show_frames",
             "-show_entries", fields,
             "-of", "compact=p=1:nk=0", media.url.path],
            timeout: 120, limit: maxIndexBytes
        )
        // This release intentionally fails on very large indexes rather than
        // approximating decoded PTS from FPS. Streaming later replaces the cap.
        return parseCompact(result.text, packets: packets)
    }
}
