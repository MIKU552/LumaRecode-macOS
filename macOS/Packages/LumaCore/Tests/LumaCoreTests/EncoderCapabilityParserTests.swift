import XCTest
@testable import LumaCore

final class EncoderCapabilityParserTests: XCTestCase {
    func testParsesClassicAndExpandedFlagColumns() {
        let listing = """
        Filters:
          T.. = Timeline support
          .S. = Slice threading
         ... format            V->V       Convert format
         .SC zscale            V->V       Scale with zimg
         .... setparams        V->V       Frame color metadata
         ..C acompressor      A->A       Audio filter
        """
        let filters = EncoderCapabilities.parseFilterNames(listing)
        XCTAssertTrue(filters.contains("format"))
        XCTAssertTrue(filters.contains("setparams"))
        XCTAssertTrue(filters.contains("zscale"))
        XCTAssertTrue(filters.contains("acompressor"))
        XCTAssertFalse(filters.contains("Timeline"))
    }

    func testMissingRequiredFilterIsStillRejected() throws {
        let info = MediaInfo(
            url: URL(fileURLWithPath: "/tmp/a.mp4"), codec: "h264",
            width: 160, height: 90, duration: 1, frameRate: 24,
            pixelFormat: "yuv420p", bitDepth: 8,
            primaries: "bt709", transfer: "bt709", matrix: "bt709",
            colorRange: "tv", audioCodecs: [],
            sourceColor: .sdr, dynamicHDR: false
        )
        let tools = try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                                   ffprobe: URL(fileURLWithPath: "/bin/echo"))
        let plan = try EncodingPlanner.plan(
            tools: tools, media: info,
            selection: EncodeSelection(codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/out.mkv")
        )
        let incomplete = EncoderCapabilities(
            encoders: ["libx265"], filters: ["format"], version: "fixture"
        )
        XCTAssertThrowsError(try MediaRequirements.validate(
            plan: plan, capabilities: incomplete
        ))
        let complete = EncoderCapabilities(
            encoders: ["libx265"], filters: ["format", "setparams"], version: "fixture"
        )
        try MediaRequirements.validate(plan: plan, capabilities: complete)
    }
}
