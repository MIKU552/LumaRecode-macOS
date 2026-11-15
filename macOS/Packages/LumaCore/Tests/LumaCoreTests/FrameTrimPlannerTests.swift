import XCTest
@testable import LumaCore

final class FrameTrimPlannerTests: XCTestCase {
    private func media(audio: [String] = ["aac"]) -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/source.mp4"),
            codec: "h264", width: 160, height: 96,
            duration: 1, frameRate: 24,
            pixelFormat: "yuv420p", bitDepth: 8,
            primaries: "bt709", transfer: "bt709",
            matrix: "bt709", colorRange: "tv", audioCodecs: audio,
            sourceColor: .sdr, dynamicHDR: false, timeBase: "1/12288"
        )
    }
    private func timeline() throws -> FrameTimeline {
        try FrameTimeline(frames: (0..<24).map {
            FramePoint(pts: Int64($0 * 512), duration: 512, keyFrame: $0 % 12 == 0)
        }, numerator: 1, denominator: 12288, packetIndexed: true)
    }
    private func tools() throws -> MediaTools {
        try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                       ffprobe: URL(fileURLWithPath: "/bin/echo"))
    }
    private func option(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    func testPreciseFrameWindowInFFmpegFilters() throws {
        let trim = try FrameTrimPlanner.plan(
            tools: tools(), media: media(), selection: EncodeSelection(),
            destination: URL(fileURLWithPath: "/tmp/clip.mkv"),
            timeline: timeline(), range: FrameRange(start: 5, end: 12)
        )
        let args = trim.encoding.arguments
        let vf = try XCTUnwrap(option("-vf", in: args))
        XCTAssertTrue(vf.hasPrefix("trim=start_frame=5:end_frame=12,"))
        XCTAssertTrue(vf.hasSuffix(",setpts=PTS-STARTPTS"))
        XCTAssertEqual(option("-map_chapters", in: args), "-1")
        XCTAssertEqual(option("-c:a", in: args), "aac")
        let af = try XCTUnwrap(option("-af", in: args))
        XCTAssertTrue(af.contains("atrim=start="))
        XCTAssertTrue(af.hasSuffix(",asetpts=PTS-STARTPTS"))
        XCTAssertEqual(trim.window.count, 7)
        XCTAssertFalse(args.contains("-ss")) // Conservative first implementation: no lossy seek.
    }
    func testExplicitAudioCopyRejectedAndOpusAllowed() throws {
        let t = try timeline()
        XCTAssertThrowsError(try FrameTrimPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(audio: .copy),
            destination: URL(fileURLWithPath: "/tmp/a.mkv"),
            timeline: t, range: FrameRange(start: 1, end: 5)
        ))
        let opus = try FrameTrimPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(audio: .opus),
            destination: URL(fileURLWithPath: "/tmp/a.mkv"),
            timeline: t, range: FrameRange(start: 1, end: 5)
        )
        XCTAssertEqual(option("-c:a", in: opus.encoding.arguments), "libopus")
    }
    func testNoAudioDoesNotAddAudioFilter() throws {
        let plan = try FrameTrimPlanner.plan(
            tools: tools(), media: media(audio: []),
            selection: EncodeSelection(), destination: URL(fileURLWithPath: "/tmp/a.mkv"),
            timeline: timeline(), range: FrameRange(start: 0, end: 3)
        )
        XCTAssertNil(option("-af", in: plan.encoding.arguments))
    }
    func testTimeAndFrameRangeUseOriginalEndExclusiveContract() throws {
        let t = try timeline()
        let byTime = try FrameTrimPlanner.resolve(
            in: t, startTime: 0.20, endTime: 0.51
        )
        XCTAssertEqual(byTime.start, 5)
        XCTAssertEqual(byTime.end, 13)
        let byFrame = try FrameTrimPlanner.resolve(
            in: t, startFrame: 5, endFrame: 13
        )
        XCTAssertEqual(byFrame, byTime)
    }
    func testRejectsMixedRangesAndInvalidBounds() throws {
        let t = try timeline()
        XCTAssertThrowsError(try FrameTrimPlanner.resolve(in: t))
        XCTAssertThrowsError(try FrameTrimPlanner.resolve(
            in: t, startFrame: 0, endTime: 0.5
        ))
        XCTAssertThrowsError(try FrameTrimPlanner.resolve(
            in: t, startFrame: 12, endFrame: 12
        ))
        XCTAssertThrowsError(try FrameTrimPlanner.resolve(
            in: t, startFrame: -1, endFrame: 10
        ))
        XCTAssertThrowsError(try FrameTrimPlanner.resolve(
            in: t, startTime: 0.9, endTime: 0.2
        ))
    }
}
