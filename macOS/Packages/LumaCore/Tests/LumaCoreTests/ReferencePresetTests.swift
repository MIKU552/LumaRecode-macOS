import Foundation
import XCTest
@testable import LumaCore

final class ReferencePresetTests: XCTestCase {
    func testBundledConfigIsOriginalWindowsSchema() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: RecommendedPresets.bundledJSON()
        ) as? [String: Any])
        for section in ["archive", "archive_fast_av1", "share", "audio"] {
            XCTAssertNotNil(json[section], section)
        }
    }

    func testHEVCArchiveMatchesWindows() throws {
        let p = try RecommendedPresets.software(codec: .hevc)
        XCTAssertEqual(p.encoder, "libx265")
        XCTAssertEqual(p.preset, "medium")
        XCTAssertEqual(p.quality, 23)
        XCTAssertEqual(p.pixelFormat, "yuv420p10le")
        XCTAssertEqual(p.parameters["rdoq-level"], "2")
        XCTAssertEqual(p.parameters["psy-rdoq"], "1")
    }

    func testAVCArchiveMatchesWindows() throws {
        let p = try RecommendedPresets.software(codec: .avc)
        XCTAssertEqual(p.encoder, "libx264")
        XCTAssertEqual(p.preset, "medium")
        XCTAssertEqual(p.quality, 21)
        XCTAssertEqual(p.parameters["aq-mode"], "2")
        XCTAssertEqual(p.parameters["aq-strength"], "0.8")
    }

    func testAV1StandardAndFastAreDifferentPresets() throws {
        let p = try RecommendedPresets.software(codec: .av1)
        XCTAssertEqual(p.encoder, "libsvtav1")
        XCTAssertEqual(p.preset, "4")
        XCTAssertEqual(p.quality, 32)
        XCTAssertEqual(p.logicalProcessors, 0)
        XCTAssertEqual(p.parameters["qm-min"], "8")
        let fast = try RecommendedPresets.software(codec: .av1, fastAV1: true)
        XCTAssertEqual(fast.preset, "6")
        XCTAssertEqual(fast.quality, 32)
        XCTAssertEqual(fast.logicalProcessors, 4)
        XCTAssertEqual(fast.parameters["hierarchical-levels"], "4")
        XCTAssertThrowsError(try RecommendedPresets.software(codec: .hevc, fastAV1: true))
    }

    func testAudioChoicesComeFromSameWindowsJSON() throws {
        XCTAssertEqual(try RecommendedPresets.defaultAudio(purpose: .archive, codec: .hevc), "copy")
        XCTAssertEqual(try RecommendedPresets.defaultAudio(purpose: .share, codec: .hevc), "aac")
        XCTAssertEqual(try RecommendedPresets.defaultAudio(purpose: .share, codec: .av1), "opus")
        let aac = try RecommendedPresets.lossyAudio(named: "aac")
        XCTAssertEqual(aac.encoder, "aac")
        XCTAssertEqual(aac.bitRateKbps, 256)
        XCTAssertEqual(aac.channels, 2)
        let opus = try RecommendedPresets.lossyAudio(named: "opus")
        XCTAssertEqual(opus.encoder, "libopus")
        XCTAssertEqual(opus.bitRateKbps, 192)
        XCTAssertEqual(opus.channels, 2)
    }

    func testMalformedConfigRejectedRatherThanGuessing() {
        XCTAssertThrowsError(try RecommendedPresets.software(codec: .hevc, data: Data("{}".utf8)))
    }
}
