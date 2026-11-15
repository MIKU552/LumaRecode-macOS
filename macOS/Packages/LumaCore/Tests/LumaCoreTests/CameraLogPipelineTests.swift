import Foundation
import XCTest
@testable import LumaCore

final class CameraLogPipelineTests: XCTestCase {
    private func media(
        _ source: SourceColor = .log,
        depth: Int = 10,
        range: String = "tv",
        matrix: String = ""
    ) -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/camera.mov"),
            codec: "hevc", width: 192, height: 108,
            duration: 2, frameRate: 24,
            pixelFormat: depth == 10 ? "yuv420p10le" : "yuv420p",
            bitDepth: depth, primaries: "",
            transfer: "", matrix: matrix, colorRange: range,
            audioCodecs: [], sourceColor: source, dynamicHDR: false
        )
    }

    private func tools() throws -> MediaTools {
        try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                       ffprobe: URL(fileURLWithPath: "/bin/echo"))
    }

    private func plan(
        _ info: MediaInfo,
        profile: CameraLogProfile = .applelog,
        override: Bool = false
    ) throws -> EncodingPlan {
        try EncodingPlanner.plan(
            tools: tools(), media: info,
            selection: EncodeSelection(
                purpose: .archive, codec: .hevc,
                logProfile: profile, interpretAsLog: override
            ),
            destination: URL(fileURLWithPath: "/tmp/hlg.mkv")
        )
    }

    private func argument(_ key: String, in plan: EncodingPlan) -> String? {
        guard let index = plan.arguments.firstIndex(of: key),
              plan.arguments.indices.contains(index + 1) else { return nil }
        return plan.arguments[index + 1]
    }

    func testFiveOriginalLUTsBundledAndDistinct() throws {
        XCTAssertEqual(CameraLogProfile.allCases.count, 5)
        var names: Set<String> = []
        for profile in CameraLogProfile.allCases {
            let url = try CameraLogPipeline.bundledURL(for: profile)
            XCTAssertTrue(names.insert(url.lastPathComponent).inserted)
            let data = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertGreaterThan(data[.size] as? Int ?? 0, 7_000_000)
        }
    }

    func testOriginalCameraYCbCrDefaultsAreNotGuessedFromGamut() {
        XCTAssertEqual(CameraLogProfile.pocket3.fallbackMatrix, "709")
        XCTAssertEqual(CameraLogProfile.applelog.fallbackMatrix, "2020_ncl")
        XCTAssertEqual(CameraLogProfile.applelog2.fallbackMatrix, "2020_ncl")
        XCTAssertEqual(CameraLogProfile.milog.fallbackRange, "full")
        XCTAssertEqual(CameraLogProfile.samsung.fallbackRange, "limited")
    }

    func testFloatHLGStagesMatchOriginalOrdering() throws {
        let stages = try CameraLogPipeline.filters(
            media: media(), profile: .applelog,
            resource: URL(fileURLWithPath: "/tmp/camera.cube")
        )
        XCTAssertEqual(stages[0],
                       "zscale=matrixin=2020_ncl:rangein=limited:range=full")
        XCTAssertEqual(stages[1], "format=gbrpf32le")
        XCTAssertTrue(stages[2].contains("lut3d=file=/tmp/camera.cube:interp=tetrahedral"))
        XCTAssertEqual(stages[3],
            "setparams=range=full:color_primaries=bt2020:color_trc=arib-std-b67:colorspace=gbr")
        XCTAssertEqual(stages[4],
            "zscale=matrix=2020_ncl:rangein=full:range=limited:dither=error_diffusion")
        XCTAssertEqual(stages[5], "format=yuv444p16le")
    }

    func testProfileFallbackOnlyWhenSourceTagsMissing() {
        let unknown = media(.log, range: "", matrix: "")
        XCTAssertEqual(
            CameraLogPipeline.decodingRange(media: unknown, profile: .milog),
            "full"
        )
        XCTAssertEqual(
            CameraLogPipeline.decodingMatrix(media: unknown, profile: .pocket3),
            "709"
        )
        let explicit = media(.log, range: "tv", matrix: "bt709")
        XCTAssertEqual(
            CameraLogPipeline.decodingRange(media: explicit, profile: .milog),
            "limited"
        )
        XCTAssertEqual(
            CameraLogPipeline.decodingMatrix(media: explicit, profile: .samsung),
            "709"
        )
    }

    func testPlanReplacesLogTagsWithHLGAndStripsCameraMetadata() throws {
        let planned = try plan(media())
        let chain = try XCTUnwrap(argument("-vf", in: planned))
        XCTAssertTrue(chain.contains("format=gbrpf32le,lut3d="))
        XCTAssertTrue(chain.contains("interp=tetrahedral"))
        XCTAssertTrue(chain.contains("format=yuv444p16le,format=yuv420p10le"))
        XCTAssertEqual(argument("-map_metadata", in: planned), "-1")
        XCTAssertEqual(argument("-color_primaries", in: planned), "bt2020")
        XCTAssertEqual(argument("-color_trc", in: planned), "arib-std-b67")
        XCTAssertEqual(argument("-colorspace", in: planned), "bt2020nc")
        XCTAssertEqual(argument("-pix_fmt", in: planned), "yuv420p10le")
        let x265 = try XCTUnwrap(argument("-x265-params", in: planned))
        XCTAssertTrue(x265.contains("colorprim=bt2020"))
        XCTAssertTrue(x265.contains("transfer=arib-std-b67"))
        XCTAssertTrue(x265.contains("colormatrix=bt2020nc"))
        XCTAssertEqual(planned.selection.logProfile, .applelog)
    }

    func testOutputVerificationChecksHLGNotSourceLogTransfer() throws {
        let input = media()
        let planned = try plan(input)
        var encoded = input
        encoded.codec = "hevc"
        encoded.primaries = "bt2020"
        encoded.transfer = "arib-std-b67"
        encoded.matrix = "bt2020nc"
        encoded.colorRange = "tv"
        encoded.sourceColor = .hlg
        try OutputVerifier.verify(source: input, encoded: encoded, plan: planned)
        encoded.transfer = "bt709"
        encoded.sourceColor = .sdr
        XCTAssertThrowsError(try OutputVerifier.verify(
            source: input, encoded: encoded, plan: planned
        ))
    }

    func testManualLogInterpretationIsExplicit() throws {
        let unknown = media(.unknown)
        XCTAssertThrowsError(try plan(unknown))
        _ = try plan(unknown, override: true)
        let mislabeled = media(.sdr)
        XCTAssertThrowsError(try plan(mislabeled))
        _ = try plan(mislabeled, override: true)
        XCTAssertThrowsError(try plan(media(.pq), override: true))
    }

    func testNeverConvertsLogWithoutCurveOrWithEightBitInput() throws {
        let source = media()
        XCTAssertThrowsError(try EncodingPlanner.plan(
            tools: tools(), media: source,
            selection: EncodeSelection(codec: .hevc),
            destination: URL(fileURLWithPath: "/tmp/a.mkv")
        ))
        XCTAssertThrowsError(try plan(media(.log, depth: 8)))
        XCTAssertThrowsError(try EncodingPlanner.plan(
            tools: tools(), media: source,
            selection: EncodeSelection(codec: .avc, logProfile: .applelog),
            destination: URL(fileURLWithPath: "/tmp/a.mkv")
        ))
        XCTAssertThrowsError(try EncodingPlanner.plan(
            tools: tools(), media: source,
            selection: EncodeSelection(purpose: .share, codec: .hevc,
                                       logProfile: .applelog),
            destination: URL(fileURLWithPath: "/tmp/a.mp4")
        ))
    }

    func testCameraTagsSelectSpecificProfilesWithoutDeviceNameGuessing() throws {
        func probe(_ tags: String) throws -> MediaInfo {
            let json = """
            {"streams":[{"codec_type":"video","codec_name":"hevc",
              "width":192,"height":108,"pix_fmt":"yuv420p10le",
              "color_transfer":"bt709","tags":\(tags)}],
             "format":{"duration":"1"}}
            """
            return try MediaProbe.parse(Data(json.utf8),
                                        url: URL(fileURLWithPath: "/tmp/sample.mov"))
        }
        let apple2 = try probe(
            #"{"com.apple.proapps.logcolorspace":"com.apple.apple-wide-gamut.apple-log"}"#
        )
        XCTAssertEqual(apple2.sourceColor, .log)
        XCTAssertEqual(apple2.detectedLogProfile, .applelog2)
        let samsung = try probe(
            #"{"com.samsung.android.logvideo":"1"}"#
        )
        XCTAssertEqual(samsung.detectedLogProfile, .samsung)
        let regular = try probe(
            #"{"com.apple.quicktime.camera.identifier":"iPhone 18 Pro"}"#
        )
        XCTAssertNil(regular.detectedLogProfile)
        XCTAssertEqual(regular.sourceColor, .sdr)
    }
}
