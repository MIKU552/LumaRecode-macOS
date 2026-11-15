import Foundation
import XCTest
@testable import LumaCore

final class HDRSideDataSweepTests: XCTestCase {
    private func source(staticHDR: Bool = false) -> MediaInfo {
        MediaInfo(
            url: URL(fileURLWithPath: "/tmp/sweep-source.mkv"), codec: "hevc",
            width: 160, height: 96, duration: 3, frameRate: 12,
            pixelFormat: "yuv420p10le", bitDepth: 10,
            primaries: "bt2020", transfer: "smpte2084",
            matrix: "bt2020nc", colorRange: "tv",
            audioCodecs: [], sourceColor: .pq, dynamicHDR: false,
            staticHDRMetadataPresent: staticHDR
        )
    }

    private func fixtureTool(_ lines: [String]) throws -> (MediaTools, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-side-data-\(UUID().uuidString).sh")
        // Every input record is a literal shell argument, not arbitrary code.
        let quoted = lines.map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        let shell = "#!/bin/sh\nprintf '%s\\n' \(quoted)\n"
        try shell.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path
        )
        return (try MediaTools(ffmpeg: URL(fileURLWithPath: "/bin/echo"),
                               ffprobe: file), file)
    }

    func testDetectsDynamicMetadataBeyondFirstThreeFrames() async throws {
        let lines = [
            "frame", "frame", "frame", "frame",
            "frame|side_datum/hdr_dynamic:side_data_type=HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"
        ]
        XCTAssertEqual(HDRSideDataSweep.evidence(in: lines[0]), .none)
        if case .dynamicHDR = HDRSideDataSweep.evidence(in: lines[4]) {
            // Required.
        } else {
            XCTFail("Late HDR10+ metadata must be detected.")
        }
        let (tools, file) = try fixtureTool(lines)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await HDRSideDataSweep.verifyBeforeEncoding(
                tools: tools, source: source()
            )
            XCTFail("Late HDR10+ was not rejected.")
        } catch LumaError.unsupported(let message) {
            XCTAssertTrue(message.contains("Dynamic HDR"), message)
        }
    }

    func testRejectsLateUnreportedStaticHDRMetadata() async throws {
        let (tools, file) = try fixtureTool([
            "frame", "frame", "frame",
            "frame|side_datum/mastering_display_metadata:side_data_type=Mastering display metadata"
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await HDRSideDataSweep.verifyBeforeEncoding(
                tools: tools, source: source()
            )
            XCTFail("Unexpected late HDR10 mastering metadata must not be lost.")
        } catch LumaError.unsupported {
            // Required.
        }
    }

    func testValidRepeatedStaticHDRIsAllowed() async throws {
        let (tools, file) = try fixtureTool([
            "frame|side_datum/mastering_display_metadata:side_data_type=Mastering display metadata",
            "frame|side_datum/content_light_level_metadata:side_data_type=Content light level metadata",
            "frame"
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        try await HDRSideDataSweep.verifyBeforeEncoding(
            tools: tools, source: source(staticHDR: true)
        )
    }

    func testDolbyVisionEvidenceRejected() {
        for record in [
            "frame|side_data_type=DOVI configuration record",
            "frame|side_data_type=Dolby Vision RPU",
            "frame|side_data_type=HDR10+"
        ] {
            if case .dynamicHDR = HDRSideDataSweep.evidence(in: record) {
                continue
            }
            XCTFail("Dynamic HDR evidence was ignored: \(record)")
        }
        XCTAssertEqual(
            HDRSideDataSweep.evidence(in: "frame|side_data_type=Content light level metadata"),
            .staticHDR
        )
        XCTAssertEqual(HDRSideDataSweep.evidence(in: "frame"), .none)
    }

    func testZeroDecodedFramesFailClosed() async throws {
        let (tools, file) = try fixtureTool(["header"])
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await HDRSideDataSweep.verifyBeforeEncoding(tools: tools, source: source())
            XCTFail("A successful subprocess with no frames must not validate HDR safety.")
        } catch LumaError.validationFailed {
            // Required.
        }
    }

    func testCancellationStopsBeforeLaunch() async throws {
        let (tools, file) = try fixtureTool(["frame"])
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await HDRSideDataSweep.verifyBeforeEncoding(
                tools: tools, source: source(), isCancelled: { true }
            )
            XCTFail("Cancellation should abort before ffprobe starts.")
        } catch LumaError.cancelled {
            // Required.
        }
    }

    func testLegacyAVCSourceDoesNotRunHDRDecoderSweep() async throws {
        let (tools, file) = try fixtureTool(["header"])
        defer { try? FileManager.default.removeItem(at: file) }
        var avc = source()
        avc.codec = "h264"
        try await HDRSideDataSweep.verifyBeforeEncoding(tools: tools, source: avc)
    }
}
