import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LumaPhotos

final class LivePhotoPairingTests: XCTestCase {
    func testThreeSecondWindowKeepsStillInsideClip() throws {
        let beginning = try LivePhotoWindow.resolve(duration: 12, selectedTime: 0.2)
        XCTAssertEqual(beginning.start, 0)
        XCTAssertEqual(beginning.duration, 3)
        XCTAssertEqual(beginning.stillTime, 0.2)
        let middle = try LivePhotoWindow.resolve(duration: 12, selectedTime: 6)
        XCTAssertEqual(middle.start, 4.5)
        XCTAssertEqual(middle.stillTime, 1.5)
        let ending = try LivePhotoWindow.resolve(duration: 12, selectedTime: 11.8)
        XCTAssertEqual(ending.start, 9)
        XCTAssertEqual(ending.stillTime, 2.8, accuracy: 0.0001)
    }

    func testShortAndInvalidSourceVideo() throws {
        let short = try LivePhotoWindow.resolve(duration: 0.8, selectedTime: 0.5)
        XCTAssertEqual(short.duration, 0.8)
        XCTAssertEqual(short.stillTime, 0.5)
        XCTAssertThrowsError(try LivePhotoWindow.resolve(duration: 0, selectedTime: 0))
        XCTAssertThrowsError(try LivePhotoWindow.resolve(duration: 4, selectedTime: 4))
        XCTAssertThrowsError(try LivePhotoWindow.resolve(duration: .infinity, selectedTime: 1))
        XCTAssertThrowsError(try LivePhotoWindow.resolve(duration: 4, selectedTime: -.nan))
    }

    func testJPEGHasRealAppleMakerNoteIdentifier() throws {
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-live-pair-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: location) }
        let pixels = [UInt8](repeating: 220, count: 32 * 24 * 4)
        let data = Data(pixels) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let image = try XCTUnwrap(CGImage(
            width: 32, height: 24, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let identifier = UUID()
        try LivePhotoStillMetadata.writeJPEG(image, identifier: identifier, to: location)
        XCTAssertEqual(
            try LivePhotoStillMetadata.identifier(in: location),
            identifier.uuidString
        )
        XCTAssertThrowsError(try LivePhotoStillMetadata.writeJPEG(
            image, identifier: identifier, to: location
        ))
    }
}
