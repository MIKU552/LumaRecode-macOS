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
            pixelFormat: depth == 8 ? "yuv420p" : "yuv420p\(depth)le",
            bitDepth: depth, primaries: color.isHDR ? "bt2020" : "bt709",
            transfer: color == .pq ? "smpte2084" :
                color == .hlg ? "arib-std-b67" : "bt709",
            matrix: color.isHDR ? "bt2020nc" : "bt709",
            colorRange: "tv", audioCodecs: ["aac"],
            sourceColor: color, dynamicHDR: dynamic
        )
    }
    private func tools() throws -> MediaTools {
        // Planning tests do not launch FFmpeg.
        try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                       ffprobe: URL(fileURLWithPath: "/bin/echo"))
    }
    private func value(_ key: String, _ plan: EncodingPlan) -> String? {
        guard let index = plan.arguments.firstIndex(of: key),
              plan.arguments.indices.contains(index + 1) else { return nil }
        return plan.arguments[index + 1]
    }
    private func x265(_ plan: EncodingPlan) -> Set<String> {
        Set((value("-x265-params", plan) ?? "").split(separator: ":").map(String.init))
    }

    func testSoftwareArchiveKeepsOriginalPreset() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/output.mkv")
        )
        XCTAssertEqual(value("-c:v", plan), "libx265")
        XCTAssertEqual(value("-preset", plan), "medium")
        XCTAssertEqual(value("-crf", plan), "23")
        XCTAssertEqual(value("-pix_fmt", plan), "yuv420p")
        XCTAssertTrue(x265(plan).isSuperset(of: [
            "pools=16", "log-level=warning", "rdoq-level=2", "psy-rdoq=1",
            "colorprim=bt709", "transfer=bt709", "colormatrix=bt709"
        ]))
        XCTAssertEqual(value("-c:a", plan), "copy")
        XCTAssertEqual(value("-fps_mode:v", plan), "passthrough")
    }
    func testSoftwareHEVCSignalsPQInBitstream() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(color: .pq, depth: 10),
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/hdr-output.mkv")
        )
        XCTAssertTrue(x265(plan).isSuperset(of: [
            "rdoq-level=2", "psy-rdoq=1", "colorprim=bt2020",
            "transfer=smpte2084", "colormatrix=bt2020nc"
        ]))
        XCTAssertEqual(value("-color_trc", plan), "smpte2084")
    }
    func testSoftwareHEVCSignalsHLGInBitstream() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(color: .hlg, depth: 10),
            selection: EncodeSelection(purpose: .archive, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/hlg-output.mkv")
        )
        XCTAssertTrue(x265(plan).contains("transfer=arib-std-b67"))
        XCTAssertTrue(x265(plan).contains("colorprim=bt2020"))
        XCTAssertEqual(value("-color_trc", plan), "arib-std-b67")
    }
    func testArchiveAV1FastComesFromReferenceJSON() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(depth: 10),
            selection: EncodeSelection(codec: .av1, variant: .fast),
            destination: URL(fileURLWithPath: "/tmp/fast-av1.mkv")
        )
        XCTAssertEqual(value("-c:v", plan), "libsvtav1")
        XCTAssertEqual(value("-preset", plan), "6")
        XCTAssertEqual(value("-crf", plan), "32")
        let parameters = Set((value("-svtav1-params", plan) ?? "")
            .split(separator: ":").map(String.init))
        XCTAssertTrue(parameters.isSuperset(of: [
            "lp=4", "tune=0", "enable-qm=1",
            "qm-min=8", "qm-max=15", "hierarchical-levels=4"
        ]))
    }
    func testExplicitOpusUsesOriginalAudioConfig() throws {
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: media(),
            selection: EncodeSelection(audio: .opus),
            destination: URL(fileURLWithPath: "/tmp/opus.mkv")
        )
        XCTAssertEqual(value("-c:a", plan), "libopus")
        XCTAssertEqual(value("-b:a", plan), "192k")
        XCTAssertEqual(value("-ac", plan), "2")
        XCTAssertEqual(value("-ar", plan), "48000")
    }
    func testFullToLimitedNeedsRealSampleConversion() throws {
        var source = media()
        source.colorRange = "pc"
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: source,
            selection: EncodeSelection(purpose: .share, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/limited.mp4")
        )
        let filter = try XCTUnwrap(value("-vf", plan))
        XCTAssertTrue(filter.contains("zscale=rangein=full:range=limited"))
        XCTAssertEqual(value("-color_range", plan), "tv")
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
        XCTAssertEqual(value("-c:v", plan), "hevc_videotoolbox")
        XCTAssertEqual(value("-q:v", plan), "65")
        XCTAssertEqual(value("-allow_sw", plan), "0")
        XCTAssertEqual(value("-tag:v", plan), "hvc1")
        XCTAssertEqual(value("-c:a", plan), "aac")
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
