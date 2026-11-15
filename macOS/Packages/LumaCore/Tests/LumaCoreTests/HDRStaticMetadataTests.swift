import Foundation
import XCTest
@testable import LumaCore

final class HDRStaticMetadataTests: XCTestCase {
    private let mastering = """
    {"side_data_type":"Mastering display metadata",
     "green_x":"13250/50000","green_y":"34500/50000",
     "blue_x":"7500/50000","blue_y":"3000/50000",
     "red_x":"34000/50000","red_y":"16000/50000",
     "white_point_x":"15635/50000","white_point_y":"16450/50000",
     "max_luminance":"10000000/10000","min_luminance":"50/10000"}
    """
    private let content = """
    {"side_data_type":"Content light level metadata",
     "max_content":1000,"max_average":400}
    """

    private func probe(master: String? = nil, light: String? = nil) throws -> MediaInfo {
        let data = """
        {"format":{"duration":"1.0"},
         "streams":[{"codec_type":"video","index":0,"codec_name":"hevc",
           "width":160,"height":96,"pix_fmt":"yuv420p10le",
           "color_range":"tv","color_primaries":"bt2020",
           "color_transfer":"smpte2084","color_space":"bt2020nc",
           "avg_frame_rate":"12/1"}],
         "frames":[{"side_data_list":[\(master ?? mastering),\(light ?? content)]}]}
        """
        return try MediaProbe.parse(
            Data(data.utf8), url: URL(fileURLWithPath: "/tmp/hdr-source.mkv")
        )
    }

    private func plan(
        _ media: MediaInfo, selection: EncodeSelection = EncodeSelection()
    ) throws -> EncodingPlan {
        try EncodingPlanner.plan(
            tools: try MediaTools(
                ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                ffprobe: URL(fileURLWithPath: "/bin/echo")
            ),
            media: media, selection: selection,
            destination: URL(fileURLWithPath:
                selection.purpose == .share ? "/tmp/hdr.mp4" : "/tmp/hdr.mkv")
        )
    }

    private func params(_ plan: EncodingPlan) throws -> [String] {
        let index = try XCTUnwrap(plan.arguments.firstIndex(of: "-x265-params"))
        return plan.arguments[index + 1].split(separator: ":").map(String.init)
    }

    func testParsesExactRationalSEIAndBuildsReferenceX265Values() throws {
        let source = try probe()
        XCTAssertEqual(source.sourceColor, .pq)
        XCTAssertTrue(source.staticHDRMetadataPresent)
        let staticData = try XCTUnwrap(source.hdrStaticMetadata)
        XCTAssertEqual(staticData.masteringDisplay?["red_x"], 0.68)
        XCTAssertEqual(staticData.masteringDisplay?["min_luminance"], 0.005)
        XCTAssertEqual(staticData.contentLight?["max_content"], 1000)
        XCTAssertEqual(staticData.contentLight?["max_average"], 400)

        let options = try staticData.hevcParameters()
        XCTAssertTrue(options.contains(
            "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
        ))
        XCTAssertTrue(options.contains("max-cll=1000,400"))
        XCTAssertTrue(options.contains("hdr10=1"))
        XCTAssertTrue(options.contains("hdr10-opt=1"))
        XCTAssertTrue(options.contains("repeat-headers=1"))

        let planned = try plan(source)
        let encoder = try params(planned)
        for option in options { XCTAssertTrue(encoder.contains(option), option) }
        XCTAssertEqual(planned.expectedCodec, .hevc)
    }

    func testVerifierFailsClosedOnMissingOrChangedMetadata() throws {
        let source = try probe()
        let planned = try plan(source)
        var output = source
        output.url = planned.temporary
        try OutputVerifier.verify(source: source, encoded: output, plan: planned)

        output.hdrStaticMetadata = nil
        XCTAssertThrowsError(
            try OutputVerifier.verify(source: source, encoded: output, plan: planned)
        )
        output = try probe(light: """
        {"side_data_type":"Content light level metadata",
         "max_content":901,"max_average":400}
        """)
        XCTAssertThrowsError(
            try OutputVerifier.verify(source: source, encoded: output, plan: planned)
        )
        output = try probe(master: mastering.replacingOccurrences(
            of: "13250/50000", with: "13500/50000"
        ))
        XCTAssertThrowsError(
            try OutputVerifier.verify(source: source, encoded: output, plan: planned)
        )
    }

    func testInvalidAndInconsistentFrameMetadataNeverEncodes() throws {
        let missing = try probe(master: """
        {"side_data_type":"Mastering display metadata",
         "red_x":"34000/50000"}
        """)
        XCTAssertTrue(missing.staticHDRMetadataPresent)
        XCTAssertNil(missing.hdrStaticMetadata)
        XCTAssertThrowsError(try plan(missing))
        let zeroDenominator = try probe(master: mastering.replacingOccurrences(
            of: "34000/50000", with: "34000/0"
        ))
        XCTAssertNil(zeroDenominator.hdrStaticMetadata)
        XCTAssertThrowsError(try plan(zeroDenominator))

        let source = try probe()
        let first = try XCTUnwrap(source.hdrStaticMetadata)
        // The source's first two frames have conflicting mastering displays.
        let document = """
        {"streams":[{"codec_type":"video","codec_name":"hevc",
          "width":160,"height":96,"pix_fmt":"yuv420p10le",
          "color_primaries":"bt2020","color_transfer":"smpte2084",
          "color_space":"bt2020nc"}],
         "frames":[
          {"side_data_list":[\(mastering),\(content)]},
          {"side_data_list":[\(mastering.replacingOccurrences(
              of: "13250/50000", with: "15000/50000"
          )),\(content)]}]}
        """
        let inconsistent = try MediaProbe.parse(
            Data(document.utf8), url: URL(fileURLWithPath: "/tmp/conflict.mkv")
        )
        XCTAssertTrue(inconsistent.staticHDRMetadataPresent)
        XCTAssertNil(inconsistent.hdrStaticMetadata)
        XCTAssertThrowsError(try plan(inconsistent))
        XCTAssertTrue(first.equivalent(to: first))
    }

    func testStaticHDRRejectsUnvalidatedAV1HardwareAndHLGPaths() throws {
        let source = try probe()
        XCTAssertThrowsError(try plan(
            source, selection: EncodeSelection(purpose: .archive, codec: .av1)
        ))
        XCTAssertThrowsError(try plan(
            source, selection: EncodeSelection(purpose: .share, codec: .hevc)
        ))
        var hlg = source
        hlg.sourceColor = .hlg
        hlg.transfer = "arib-std-b67"
        XCTAssertThrowsError(try plan(hlg))
        var wrong = source
        wrong.dynamicHDR = true
        XCTAssertThrowsError(try plan(wrong))
    }

    func testHDRValidationRejectsOutOfRangeAndNonFiniteLuminance() throws {
        let overshoot = try probe(master: mastering.replacingOccurrences(
            of: "13250/50000", with: "100000/50000"
        ))
        let staticData = try XCTUnwrap(overshoot.hdrStaticMetadata)
        XCTAssertThrowsError(try staticData.hevcParameters())
        XCTAssertThrowsError(try plan(overshoot))

        let huge = try probe(master: mastering.replacingOccurrences(
            of: "10000000/10000", with: "1e308"
        ))
        let hugeData = try XCTUnwrap(huge.hdrStaticMetadata)
        XCTAssertThrowsError(try hugeData.hevcParameters())
    }
}
