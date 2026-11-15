import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import LumaCore
import Photos
import XCTest
@testable import LumaPhotos

final class AppleLivePhotoTests: XCTestCase {
    func testNativeApplePairFromRealSDRMovie() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_LIVE_PHOTO_CI"] == "1" else {
            throw XCTSkip("Real native Live Photo pair uses the macOS FFmpeg integration job.")
        }
        let tools = try MediaTools.resolve()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-live-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sdr.mp4")
        let command = try await CommandCapture.run(tools.ffmpeg, [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=duration=3.5:size=160x96:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=550:duration=3.5",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-preset", "medium", "-bf", "3",
            "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
            "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-movflags", "+faststart", source.path
        ], timeout: 90)
        XCTAssertEqual(command.code, 0)
        let media = try await MediaProbe.inspect(tools: tools, url: source)
        XCTAssertEqual(media.sourceColor, .sdr)
        let pair = try await AppleLivePhotoExporter.export(
            from: media, selectedTime: 1.75, to: folder, name: "live-sdr"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.still.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.movie.path))
        XCTAssertEqual(try LivePhotoStillMetadata.identifier(in: pair.still),
                       pair.identifier)
        let still = try XCTUnwrap(CGImageSourceCreateWithURL(pair.still as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(still), 1)
        let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(still, 0, nil)
                                  as? [String: Any])
        XCTAssertEqual(info[kCGImagePropertyPixelWidth as String] as? Int, 160)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight as String] as? Int, 96)
        try await LivePhotoPairVerifier.verify(
            still: pair.still, movie: pair.movie,
            expectedIdentifier: pair.identifier,
            expectedStillTime: pair.stillTime
        )
        let movie = AVURLAsset(url: pair.movie)
        let videoTracks = try await movie.loadTracks(withMediaType: .video)
        let audioTracks = try await movie.loadTracks(withMediaType: .audio)
        let metadataTracks = try await movie.loadTracks(withMediaType: .metadata)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
        XCTAssertFalse(metadataTracks.isEmpty)
        XCTAssertLessThan(pair.stillTime, 3)

        // The pair is only considered complete once Photos can construct the
        // in-memory Live Photo without adding it to a user's library.
        let expectation = expectation(description: "Apple Photos loads actual paired resources")
        let requestID = PHLivePhoto.request(
            withResourceFileURLs: [pair.still, pair.movie],
            placeholderImage: nil, targetSize: CGSize(width: 160, height: 96),
            contentMode: .aspectFit
        ) { livePhoto, details in
            if details[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
            XCTAssertNotNil(livePhoto, "Apple Photos refused the JPEG + MOV pairing: \(details)")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 30)
        PHLivePhoto.cancelRequest(withRequestID: requestID)
    }

    func testRejectsUnsupportedHDRAndExistingPairBeforeWriting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-live-unsafe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = MediaInfo(
            url: dir.appendingPathComponent("unknown.mp4"), codec: "hevc",
            width: 160, height: 96, duration: 3, frameRate: 24,
            pixelFormat: "yuv420p10le", bitDepth: 10,
            primaries: "bt2020", transfer: "smpte2084",
            matrix: "bt2020nc", colorRange: "tv", audioCodecs: [],
            sourceColor: .pq, dynamicHDR: false
        )
        do {
            _ = try await AppleLivePhotoExporter.export(
                from: media, selectedTime: 1, to: dir, name: "hdr"
            )
            XCTFail("10-bit PQ must not be silently converted to 8-bit SDR Live Photo.")
        } catch LumaError.unsupported {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("hdr.jpg").path
        ))
    }
}
