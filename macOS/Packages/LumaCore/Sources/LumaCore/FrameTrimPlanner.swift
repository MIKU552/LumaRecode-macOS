import Foundation

/// A frame-accurate trim plan. Zero-based, end-exclusive frame selection.
/// The output is verified by decoding and counting frames before publication.
public struct TrimmedEncodingPlan: Sendable {
    public let encoding: EncodingPlan
    public let window: FrameWindow

    public init(encoding: EncodingPlan, window: FrameWindow) {
        self.encoding = encoding
        self.window = window
    }
}

/// Port of the behavioral contract in Windows Transcoder.Frames.cs,
/// Transcoder.cs (trim/setpts/audio filters), and NativeCli.Frames.cs.
/// Native Swift planning; no .NET runtime. First release decodes from the
/// beginning to avoid fast-seek/keyframe reordering ambiguity for B-frames/VFR.
public enum FrameTrimPlanner {
    public static func resolve(
        in timeline: FrameTimeline,
        startFrame: Int? = nil, endFrame: Int? = nil,
        startTime: Double? = nil, endTime: Double? = nil
    ) throws -> FrameRange {
        let usingFrames = startFrame != nil || endFrame != nil
        let usingTimes = startTime != nil || endTime != nil
        guard usingFrames != usingTimes else {
            throw LumaError.invalidInput(
                "Specify either --start-frame/--end-frame or --start-time/--end-time."
            )
        }
        let range: FrameRange
        if usingTimes {
            func index(_ seconds: Double, label: String) throws -> Int {
                guard seconds.isFinite, seconds >= 0, seconds <= timeline.duration else {
                    throw LumaError.invalidInput("Invalid \(label); expected a time within the video.")
                }
                return try timeline.atOrAfter(seconds)
            }
            range = try FrameRange(
                start: index(startTime ?? 0, label: "start time"),
                end: index(endTime ?? timeline.duration, label: "end time")
            )
        } else {
            range = FrameRange(start: startFrame ?? 0, end: endFrame)
        }
        _ = try timeline.resolve(range)
        return range
    }

    public static func plan(
        tools: MediaTools,
        media: MediaInfo,
        selection: EncodeSelection,
        destination: URL,
        timeline: FrameTimeline,
        range: FrameRange
    ) throws -> TrimmedEncodingPlan {
        let window = try timeline.resolve(range)
        guard window.duration.isFinite && window.duration > 0 else {
            throw LumaError.invalidInput("The frame selection has no valid positive duration.")
        }
        guard window.startSeconds.isFinite, window.endSeconds.isFinite,
              window.startSeconds >= 0 else {
            throw LumaError.unsupported(
                "Negative source timestamps require additional audio-origin alignment validation."
            )
        }
        guard selection.audio != .copy || media.audioCodecs.isEmpty else {
            throw LumaError.invalidInput(
                "Frame-accurate trim cannot copy audio: select automatic, AAC, or Opus."
            )
        }
        var effective = selection
        // Windows FrameOptions: archive's automatic audio-copy must become
        // re-encoded audio when trimming, avoiding uncut audio duration.
        if !media.audioCodecs.isEmpty && selection.audio == .automatic {
            effective.audio = .aac
        }
        let base = try EncodingPlanner.plan(
            tools: tools, media: media, selection: effective,
            destination: destination
        )
        var arguments = base.arguments
        guard let videoFilter = arguments.firstIndex(of: "-vf"),
              arguments.indices.contains(videoFilter + 1),
              let chapter = arguments.firstIndex(of: "-map_chapters"),
              arguments.indices.contains(chapter + 1) else {
            throw LumaError.validationFailed("The encoding plan has no expected filter or chapter flags.")
        }
        // FFmpeg trim counts frames *after decoding* (presentation order), not
        // packets in the demuxer's DTS order. Decode from start for correctness.
        arguments[videoFilter + 1] = [
            "trim=start_frame=\(window.start):end_frame=\(window.end)",
            arguments[videoFilter + 1],
            "setpts=PTS-STARTPTS"
        ].joined(separator: ",")
        arguments[chapter + 1] = "-1"

        if !media.audioCodecs.isEmpty {
            let first = String(format: "%.17g", window.startSeconds)
            let last = String(format: "%.17g", window.endSeconds)
            let audioFilter = "atrim=start=\(first):end=\(last),asetpts=PTS-STARTPTS"
            // The last argument is the temporary output path.
            arguments.insert(contentsOf: ["-af", audioFilter], at: arguments.count - 1)
        }

        let plan = EncodingPlan(
            executable: base.executable, arguments: arguments,
            destination: base.destination, temporary: base.temporary,
            selection: effective, expectedCodec: base.expectedCodec,
            inputColor: base.inputColor
        )
        return TrimmedEncodingPlan(encoding: plan, window: window)
    }
}
