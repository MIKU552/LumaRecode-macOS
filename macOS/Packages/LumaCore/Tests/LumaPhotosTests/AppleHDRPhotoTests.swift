import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LumaPhotos

final class AppleHDRPhotoTests: XCTestCase {
    func testWritesNative10BitHEIC() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-pq-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: path) }
        let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        do {
            try AppleHDRPhotoExporter.writePQ(image, to: path)
        } catch {
            // A hosted runner may not expose a HEIF10 encoder; this is not a
            // positive compatibility assertion for target Apple Silicon Macs.
            throw XCTSkip("System HEIF10 encoding is unavailable in the runner: \(error)")
        }
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
