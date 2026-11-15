import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumaCore
import XCTest
@testable import LumaPhotos

final class AppleHDRPhotoTests: XCTestCase {
    func testExportsPQFrameFromNative10BitVideo() async throws {
        guard ProcessInfo.processInfo.environment["LUMA_PQ_VIDEO_CI"] == "1" else {
            throw XCTSkip("Real HDR media integration runs in the FFmpeg smoke-test job.")
        }
        let tools = try MediaTools.resolve()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-hdr-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("pq-source.mp4")
        let photo = directory.appendingPathComponent("pq-frame.heic")
        let output = try await CommandCapture.run(tools.ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=duration=0.8:size=160x90:rate=24",
            "-vf", "format=yuv420p10le",
            "-c:v", "libx265", "-preset", "ultrafast",
            // x265 must write HDR VUI into the HEVC bitstream, not just
            // the FFmpeg muxer-level color flags.
            "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
            "-pix_fmt", "yuv420p10le",
            "-color_primaries", "bt2020", "-color_trc", "smpte2084",
            "-colorspace", "bt2020nc",
            // AVFoundation and QuickTime expect hvc1 for HEVC in MP4.
            "-tag:v", "hvc1",
            "-an", input.path
        ], timeout: 90)
        XCTAssertEqual(output.code, 0)
        let tag = try await CommandCapture.run(tools.ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_tag_string",
            "-of", "default=nw=1:nk=1", input.path
        ], timeout: 20)
        XCTAssertEqual(tag.text.trimmingCharacters(in: .whitespacesAndNewlines), "hvc1")
        let media = try await MediaProbe.inspect(tools: tools, url: input)
        XCTAssertEqual(media.sourceColor, .pq, "Test source HEVC VUI must declare PQ.")
        XCTAssertEqual(media.bitDepth, 10, "Test source must be 10-bit.")
        XCTAssertEqual(media.primaries, "bt2020", "Test source HEVC VUI must declare BT.2020.")
        XCTAssertEqual(media.matrix, "bt2020nc", "Test source must declare BT.2020 NCL.")
        guard media.sourceColor == .pq, media.primaries == "bt2020",
              media.matrix == "bt2020nc", media.bitDepth == 10 else {
            return // Source preconditions failed; do not misattribute to the Apple HEIC encoder.
        }
        try await AppleHDRPhotoExporter.exportPQ(from: media, at: 0.25, to: photo)
        let result = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(result), 1)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 160)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 90)
    }

    func testWritesNative10BitHEIC() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-pq-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: path) }
        let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        // This is a required test, not a skipped compatibility claim.
        // A HEIF10 encoder failure must fail CI.
        try AppleHDRPhotoExporter.writePQ(image, to: path)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        let width = props[kCGImagePropertyPixelWidth] as? Int
        let height = props[kCGImagePropertyPixelHeight] as? Int
        XCTAssertEqual(width, 96)
        XCTAssertEqual(height, 64)
    }
}
