import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exports *SDR* frames using Apple's system frameworks. HDR HEIC gain-map
/// export is intentionally not claimed until proper HDR pipeline verification.
enum StillFormat: String, CaseIterable, Identifiable {
    case heic, jpeg, png
    var id: String { rawValue }
    var label: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        }
    }
    var type: UTType {
        switch self {
        case .heic: return .heic
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }
}

enum StillExporter {
    static func export(
        source: URL, to destination: URL,
        seconds: Double, format: StillFormat, quality: Double
    ) async throws {
        guard seconds.isFinite, seconds >= 0, quality.isFinite, quality > 0, quality <= 1 else {
            throw LumaError.invalidInput("Invalid frame position or quality.")
        }
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: source)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try generator.copyCGImage(
                at: CMTime(seconds: seconds, preferredTimescale: 600),
                actualTime: nil
            )
            let temp = destination.deletingLastPathComponent().appendingPathComponent(
                ".luma-\(UUID().uuidString).\(format.rawValue)"
            )
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let writer = CGImageDestinationCreateWithURL(
                temp as CFURL, format.type.identifier as CFString, 1, nil
            ) else { throw LumaError.processFailed("Cannot create Apple ImageIO destination.") }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
            CGImageDestinationAddImage(writer, frame, properties as CFDictionary)
            guard CGImageDestinationFinalize(writer) else {
                throw LumaError.processFailed("ImageIO could not encode this image.")
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw LumaError.invalidInput("Destination already exists.")
            }
            try FileManager.default.moveItem(at: temp, to: destination)
        }.value
    }
}
