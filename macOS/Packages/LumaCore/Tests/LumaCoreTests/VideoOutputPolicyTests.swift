import XCTest
@testable import LumaCore

final class VideoOutputPolicyTests: XCTestCase {
    private func media(_ pixel: String, depth: Int = 10, color: SourceColor = .sdr,
                       range: String = "tv") -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/tmp/input.mkv"), codec: "hevc",
                  width: 1920, height: 1080, duration: 4, frameRate: 24,
                  pixelFormat: pixel, bitDepth: depth,
                  primaries: color.isHDR ? "bt2020" : "bt709",
                  transfer: color == .pq ? "smpte2084" : color == .hlg ? "arib-std-b67" : "bt709",
                  matrix: color.isHDR ? "bt2020nc" : "bt709",
                  colorRange: range, audioCodecs: ["aac"],
                  sourceColor: color, dynamicHDR: false)
    }

    func testArchivePreservesOriginalChromaAndDepth() throws {
        let resolved = try VideoOutputPolicy.resolve(
            media("yuv422p10le"),
            selection: EncodeSelection(purpose: .archive, codec: .hevc)
        )
        XCTAssertEqual(resolved.sampling, "422")
        XCTAssertEqual(resolved.bitDepth, 10)
        XCTAssertEqual(resolved.pixelFormat, "yuv422p10le")
        XCTAssertEqual(resolved.audio, "copy")
    }

    func testShareUses420AndLimitedRange() throws {
        let result = try VideoOutputPolicy.resolve(
            media("yuv444p10le", range: "pc"),
            selection: EncodeSelection(purpose: .share, codec: .hevc)
        )
        XCTAssertEqual(result.sampling, "420")
        XCTAssertEqual(result.bitDepth, 8)
        XCTAssertEqual(result.sourceRange, "full")
        XCTAssertEqual(result.sampleRange, "limited")
    }

    func testNeverUpsamplesChroma() throws {
        XCTAssertEqual(VideoOutputPolicy.supportedSampling(media("yuv420p10le")), ["420"])
        XCTAssertEqual(VideoOutputPolicy.supportedSampling(media("yuv422p10le")), ["420", "422"])
        XCTAssertEqual(VideoOutputPolicy.supportedSampling(media("yuv444p10le")), ["420", "422", "444"])
        XCTAssertThrowsError(try VideoOutputPolicy.resolve(
            media("yuv420p10le"),
            selection: EncodeSelection(sampling: .yuv444)
        ))
    }

    func testTwelveBitSoftwareHEVCAndAV1Limit() throws {
        XCTAssertEqual(try VideoOutputPolicy.resolve(
            media("yuv420p12le", depth: 12),
            selection: EncodeSelection(codec: .hevc)).bitDepth, 12)
        XCTAssertEqual(try VideoOutputPolicy.resolve(
            media("yuv420p12le", depth: 12),
            selection: EncodeSelection(codec: .av1)).bitDepth, 10)
    }

    func testHDRRejectsAVCAndEightBitSources() throws {
        XCTAssertThrowsError(try VideoOutputPolicy.resolve(
            media("yuv420p10le", color: .pq),
            selection: EncodeSelection(codec: .avc)))
        XCTAssertThrowsError(try VideoOutputPolicy.resolve(
            media("yuv420p", depth: 8, color: .hlg),
            selection: EncodeSelection(codec: .hevc)))
    }

    func testAV1FastOnlyOnSoftwareArchive() throws {
        let fast = EncodeSelection(codec: .av1, variant: .fast)
        XCTAssertEqual(try VideoOutputPolicy.resolve(
            media("yuv420p10le"), selection: fast).sampling, "420")
        XCTAssertThrowsError(try VideoOutputPolicy.resolve(
            media("yuv420p10le"),
            selection: EncodeSelection(codec: .hevc, variant: .fast)))
    }

    func testGrayAndP010SourceFormats() throws {
        XCTAssertEqual(VideoOutputPolicy.sourceSampling(media("gray10le")), "gray")
        XCTAssertEqual(VideoOutputPolicy.sourceSampling(media("p010le")), "420")
    }
}
