import Foundation
import XCTest
@testable import LumaCore

final class OutputVerifierTests: XCTestCase {
    private func media(
        pixel: String = "yuv420p", depth: Int = 8,
        color: SourceColor = .sdr
    ) -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/source.mp4"), codec: "h264",
            width: 160, height: 90, duration: 1, frameRate: 24,
            pixelFormat: pixel, bitDepth: depth,
            primaries: color.isHDR ? "bt2020" : "bt709",
            transfer: color == .pq ? "smpte2084" :
                color == .hlg ? "arib-std-b67" : "bt709",
            matrix: color.isHDR ? "bt2020nc" : "bt709",
            colorRange: "tv", audioCodecs: ["aac", "flac"],
            sourceColor: color, dynamicHDR: false
        )
    }

    private func tools() throws -> MediaTools {
        try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                       ffprobe: URL(fileURLWithPath: "/bin/echo"))
    }

    private func archivePlan(_ source: MediaInfo) throws -> EncodingPlan {
        try EncodingPlanner.plan(tools: tools(), media: source,
                                 selection: EncodeSelection(purpose: .archive, codec: .hevc),
                                 destination: URL(fileURLWithPath: "/tmp/out.mkv"))
    }

    func testValidCopyAndColorimetryPass() throws {
        let source = media()
        let plan = try archivePlan(source)
        var result = source
        result.codec = "hevc"
        result.url = plan.temporary
        try OutputVerifier.verify(source: source, encoded: result, plan: plan)
    }

    func testRejectsPixelFormatMismatchEvenIfCodecMatches() throws {
        let source = media(pixel: "yuv422p10le", depth: 10)
        let plan = try archivePlan(source)
        var result = source
        result.codec = "hevc"
        result.pixelFormat = "yuv420p10le"
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: result, plan: plan))
    }

    func testRejectsColorTransferAndSampleRangeLoss() throws {
        let source = media(pixel: "yuv420p10le", depth: 10, color: .pq)
        let plan = try archivePlan(source)
        var wrong = source
        wrong.codec = "hevc"
        wrong.transfer = "bt709"
        wrong.sourceColor = .sdr
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: wrong, plan: plan))
        wrong = source
        wrong.codec = "hevc"
        wrong.colorRange = "pc"
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: wrong, plan: plan))
    }

    func testRejectsMissingOrReorderedCopiedAudio() throws {
        let source = media()
        let plan = try archivePlan(source)
        var result = source
        result.codec = "hevc"
        result.audioCodecs = ["aac"]
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: result, plan: plan))
        result.audioCodecs = ["flac", "aac"]
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: result, plan: plan))
    }

    func testRejectsChangedDimensions() throws {
        let source = media()
        let plan = try archivePlan(source)
        var result = source
        result.codec = "hevc"
        result.width = 144
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: result, plan: plan))
    }

    func testDisplayMatrixRotationSwapsExpectedDimensions() throws {
        var source = media()
        source.displayRotation = -90
        let plan = try archivePlan(source)
        var result = source
        result.codec = "hevc"
        result.width = 90
        result.height = 160
        try OutputVerifier.verify(source: source, encoded: result, plan: plan)
    }

    func testShareHEVCRequiresHVC1AndExpectedAudioCodec() throws {
        let source = media()
        let plan = try EncodingPlanner.plan(
            tools: tools(), media: source,
            selection: EncodeSelection(purpose: .share, codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/out.mp4")
        )
        var result = source
        result.codec = "hevc"
        result.codecTag = "hev1"
        result.audioCodecs = ["aac", "aac"]
        XCTAssertThrowsError(try OutputVerifier.verify(source: source, encoded: result, plan: plan))
        result.codecTag = "hvc1"
        try OutputVerifier.verify(source: source, encoded: result, plan: plan)
    }

    func testProbeSelectsAbsolutePlayableStreamIndexPastAttachedArt() throws {
        let doc = """
        {"streams":[
            {"codec_type":"video","index":0,"codec_name":"mjpeg","pix_fmt":"yuvj420p",
                "disposition":{"attached_pic":1}},
            {"codec_type":"audio","index":1,"codec_name":"aac"},
            {"codec_type":"video","index":2,"codec_name":"h264","width":160,"height":90,
                "pix_fmt":"yuv420p","color_primaries":"bt709",
                "color_transfer":"bt709","color_space":"bt709","color_range":"tv",
                "disposition":{"attached_pic":0}}
        ],"format":{"duration":"1"}}
        """
        let parsed = try MediaProbe.parse(Data(doc.utf8),
                                          url: URL(fileURLWithPath: "/tmp/cover.mp4"))
        XCTAssertEqual(parsed.videoStreamIndex, 2)
        let plan = try archivePlan(parsed)
        XCTAssertTrue(plan.arguments.contains("0:2"))
        XCTAssertFalse(plan.arguments.contains("0:v:0"))
    }

    func testProbeRecognizesStaticHDRMetadataAndPlannerBlocksLoss() throws {
        let doc = """
        {"streams":[{"codec_type":"video","index":0,"codec_name":"hevc",
           "width":160,"height":90,"pix_fmt":"yuv420p10le",
           "color_primaries":"bt2020","color_transfer":"smpte2084",
           "color_space":"bt2020nc",
           "side_data_list":[{"side_data_type":"Mastering display metadata"}]}],
         "format":{"duration":"1"}}
        """
        let parsed = try MediaProbe.parse(Data(doc.utf8),
                                          url: URL(fileURLWithPath: "/tmp/hdr.mp4"))
        XCTAssertTrue(parsed.staticHDRMetadataPresent)
        XCTAssertThrowsError(try archivePlan(parsed))
    }
}
