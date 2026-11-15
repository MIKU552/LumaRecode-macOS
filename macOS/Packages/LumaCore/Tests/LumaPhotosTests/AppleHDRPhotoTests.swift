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
