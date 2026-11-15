import XCTest
@testable import LumaCore

final class MediaRequirementsTests: XCTestCase {
    private func media(range: String = "tv") -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/input.mp4"), codec: "h264",
            width: 160, height: 96, duration: 2, frameRate: 24,
            pixelFormat: "yuv420p", bitDepth: 8,
            primaries: "bt709", transfer: "bt709", matrix: "bt709",
            colorRange: range, audioCodecs: ["aac"],
            sourceColor: .sdr, dynamicHDR: false
        )
    }
    private func plan(range: String = "tv", audio: AudioChoice = .automatic) throws -> EncodingPlan {
        let tools = try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                                   ffprobe: URL(fileURLWithPath: "/bin/echo"))
        return try EncodingPlanner.plan(
            tools: tools, media: media(range: range),
            selection: EncodeSelection(
                purpose: .archive, codec: .hevc, colorRange: .limited, audio: audio
            ), destination: URL(fileURLWithPath: "/tmp/archive.mkv")
        )
    }
    func testRequirementsCheckSelectedVideoAndFilterSet() throws {
        let config = EncoderCapabilities(
            encoders: ["libx265", "aac", "libopus"],
            filters: ["setparams", "format", "zscale"], version: "fixture"
        )
        try MediaRequirements.validate(plan: plan(range: "pc"), capabilities: config)
    }
    func testRejectsMissingVideoEncoder() throws {
        let config = EncoderCapabilities(
            encoders: ["libx264", "aac"], filters: ["setparams", "format", "zscale"], version: ""
        )
        XCTAssertThrowsError(try MediaRequirements.validate(
            plan: plan(), capabilities: config
        ))
    }
    func testRejectsMissingRangeConversionFilter() throws {
        let config = EncoderCapabilities(
            encoders: ["libx265"], filters: ["setparams", "format"], version: ""
        )
        XCTAssertThrowsError(try MediaRequirements.validate(
            plan: plan(range: "pc"), capabilities: config
        ))
    }
    func testOpusEncoderIsCheckedSeparatelyFromVideo() throws {
        let config = EncoderCapabilities(
            encoders: ["libx265"], filters: ["setparams", "format"], version: ""
        )
        XCTAssertThrowsError(try MediaRequirements.validate(
            plan: plan(audio: .opus), capabilities: config
        ))
    }
}
