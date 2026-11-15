import Foundation
import XCTest
@testable import LumaCore

final class PlannerTests: XCTestCase {
    private func media(
        color: SourceColor = .sdr, dynamic: Bool = false,
        depth: Int = 8
    ) -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/source.mov"), codec: "hevc",
            width: 3840, height: 2160, duration: 60, frameRate: 29.97,
            pixelFormat: depth > 8 ? "yuv420p10le" : "yuv420p",
            bitDepth: depth, primaries: "bt709", transfer: "bt709",
            matrix: "bt709", colorRange: "tv", audioCodecs: ["aac"],
            sourceColor: color, dynamicHDR: dynamic
        )
    }
    private func tools() throws -> MediaTools {
        // Tests only construct arguments. No FFmpeg process is started.
        try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                       ffprobe: URL(fileURLWithPath: "/bin/echo"))
    }
    func testSoftwareArchiveKeepsOriginalPreset() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/output.mkv")
        )
        XCTAssertTrue(plan.arguments.contains("libx265"))
        XCTAssertTrue(plan.arguments.contains("23"))
        XCTAssertTrue(plan.arguments.contains(
            "pools=16:log-level=warning:rdoq-level=2:psy-rdoq=1:colorprim=bt709:transfer=bt709:colormatrix=bt709"
        ))
        XCTAssertTrue(plan.arguments.contains("copy"))
    }
    func testSoftwareHEVCSignalsPQInBitstream() throws {
        var input = media(color: .pq, depth: 10)
        input.primaries = "bt2020"
        input.transfer = "smpte2084"
        input.matrix = "bt2020nc"
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: input,
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/hdr-output.mkv")
        )
        XCTAssertTrue(plan.arguments.contains(
            "pools=16:log-level=warning:rdoq-level=2:psy-rdoq=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
        ))
        XCTAssertTrue(plan.arguments.contains("-color_trc"))
        XCTAssertTrue(plan.arguments.contains("smpte2084"))
    }
    func testSoftwareHEVCSignalsHLGInBitstream() throws {
        var input = media(color: .hlg, depth: 10)
        input.primaries = "bt2020"
        input.transfer = "arib-std-b67"
        input.matrix = "bt2020nc"
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: input,
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/hlg-output.mkv")
        )
        XCTAssertTrue(plan.arguments.contains(
            "pools=16:log-level=warning:rdoq-level=2:psy-rdoq=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"
        ))
    }
    func testRejectsInconsistentHDRColorimetry() throws {
        let input = media(color: .pq, depth: 10) // Claims PQ, but is tagged BT.709.
        XCTAssertThrowsError(try EncodingPlanner.plan(
            tools: tools(), media: input,
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/unverified-hdr.mkv")
        ))
    }
    func testBlocksUnportedDynamicHDR() throws {
        XCTAssertThrowsError(try EncodingPlanner.plan(
            tools: tools(), media: media(color: .pq, dynamic: true, depth: 10),
            selection: EncodeSelection(), destination: URL(fileURLWithPath: "/tmp/out.mkv")
        ))
    }
    func testNativeHardwareForHEVC() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(purpose: .share, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/out.mp4")
        )
        XCTAssertTrue(plan.arguments.contains("hevc_videotoolbox"))
        XCTAssertTrue(plan.arguments.contains("65"))
        XCTAssertTrue(plan.arguments.contains("0")) // -allow_sw 0
    }
    func testNoUnverifiedAV1Hardware() throws {
        XCTAssertThrowsError(try EncodingPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(purpose: .share, codec: .av1),
            destination: URL(fileURLWithPath: "/tmp/out.mp4")
        ))
    }
    func testSensibleFileName() {
        let url = EncodingPlanner.destination(
            for: media(), selection: EncodeSelection(purpose: .archive, codec: .hevc),
            directory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(url.lastPathComponent, "source_SDR_hevc_archive.mkv")
    }
    func testProResRAWCodecIsDetected() throws {
        let json = """
        {"format":{"duration":"1"},"streams":[{"codec_type":"video","codec_name":"prores_raw",
        "width":1920,"height":1080,"pix_fmt":"bayer_rggb16le","avg_frame_rate":"24/1"}]}
        """
        let info = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/raw.mov"))
        XCTAssertEqual(info.sourceColor, .raw)
    }
    func testFrameSideDataDetectsDynamicHDR() throws {
        let json = """
        {"format":{"duration":"1"},"streams":[{"codec_type":"video","codec_name":"hevc",
         "width":1920,"height":1080,"color_transfer":"smpte2084","pix_fmt":"yuv420p10le"}],
         "frames":[{"side_data_list":[{"side_data_type":"HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}]}]}
        """
        let info = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/hdr.mp4"))
        XCTAssertTrue(info.dynamicHDR)
        XCTAssertEqual(info.sourceColor, .pq)
    }
    func testProbeParsing() throws {
        let json = """
        {"format":{"duration":"4.50"},"streams":[
          {"codec_type":"video","codec_name":"hevc","width":1920,"height":1080,
           "pix_fmt":"yuv420p10le","avg_frame_rate":"30000/1001",
           "color_transfer":"arib-std-b67","color_primaries":"bt2020","color_space":"bt2020nc"},
          {"codec_type":"audio","codec_name":"aac"}]}
        """
        let result = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/x.mp4"))
        XCTAssertEqual(result.sourceColor, .hlg)
        XCTAssertEqual(result.bitDepth, 10)
        XCTAssertEqual(result.duration, 4.5)
        XCTAssertEqual(result.audioCodecs, ["aac"])
    }
}
