import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LumaCore

/// The original Windows MotionPhoto.cs implements Google's JPEG+MP4
/// container. Apple Live Photos require a different native paired-resource
/// contract: matching MakerApple[17], QuickTime content ID and a timed
/// still-image-time metadata track. They must never be conflated.
public struct LivePhotoWindow: Equatable, Sendable {
    public let start: Double
    public let duration: Double
    public let stillTime: Double

    /// Selects up to three seconds around the user-selected poster frame.
    public static func resolve(
        duration: Double, selectedTime: Double
    ) throws -> LivePhotoWindow {
        guard duration.isFinite, selectedTime.isFinite,
              duration > 0.1, selectedTime >= 0,
              selectedTime < duration else {
            throw LumaError.invalidInput("Invalid Live Photo source duration or poster time.")
        }
        let span = min(3.0, duration)
        let start = min(max(0, selectedTime - span / 2), max(0, duration - span))
        return LivePhotoWindow(
            start: start, duration: span,
            stillTime: selectedTime - start
        )
    }
}

/// Deliberately uses ImageIO rather than copying opaque camera MakerNotes.
public enum LivePhotoStillMetadata {
    public static func writeJPEG(
        _ image: CGImage, identifier: UUID, to destination: URL
    ) throws {
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "jpg"
                || destination.pathExtension.lowercased() == "jpeg" else {
            throw LumaError.invalidInput("Apple Live Photo still must be a JPEG file.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LumaError.invalidInput("Live Photo still destination already exists.")
        }
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw LumaError.processFailed("ImageIO could not create Live Photo JPEG writer.")
        }
        let metadata: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: [
                "17": identifier.uuidString
            ],
            kCGImageDestinationLossyCompressionQuality as String: 0.95
        ]
        CGImageDestinationAddImage(writer, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw LumaError.processFailed("ImageIO failed to write the paired Live Photo still.")
        }
    }

    public static func identifier(in file: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String]
                as? [String: Any],
              let id = maker["17"] as? String,
              UUID(uuidString: id) != nil else {
            throw LumaError.validationFailed(
                "JPEG does not contain a valid Apple Live Photo MakerNote 17 identifier."
            )
        }
        return id
    }
}

public struct LivePhotoPair: Equatable, Sendable {
    public let still: URL
    public let movie: URL
    public let identifier: String
    public let stillTime: Double
}
