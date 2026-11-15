import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import LumaCore

/// Apple-native 10-bit HEIC writer. Does not create gain maps or Live Photos.
/// PQ transfer is preserved as BT.2100 PQ; no SDR tone mapping is performed.
public enum AppleHDRPhotoExporter {
    /// Writes a PQ-tagged, 10-bit HEIC from an already color-managed CIImage.
    /// The supplied image must describe the correct input color space.
    public static func writePQ(_ image: CIImage, to destination: URL) throws {
        let bounds = image.extent
        guard !bounds.isEmpty,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite else {
            throw LumaError.invalidInput("HDR photo has no finite image extent.")
        }
        guard let outputColor = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
              let workingColor = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else {
            throw LumaError.unsupported("BT.2100 PQ / extended linear BT.2020 is unavailable.")
        }
        let context = CIContext(options: [.workingColorSpace: workingColor])
        try context.writeHEIF10Representation(
            of: image, to: destination, colorSpace: outputColor
        )
        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else {
            throw LumaError.validationFailed("Apple ImageIO could not read the generated HDR HEIC.")
        }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let depth = properties[kCGImagePropertyDepth] as? NSNumber,
           depth.intValue < 10 {
            throw LumaError.validationFailed("HEIC pixel depth is below 10 bits.")
        }
    }

    /// Initial native PQ frame-extraction path; seeks close to the selected time.
    /// Not yet a substitute for LumaRecode's exact PTS / VFR frame timeline.
    public static func exportPQ(
        from media: MediaInfo, at seconds: Double, to destination: URL
    ) async throws {
        guard media.sourceColor == .pq, media.primaries == "bt2020",
              media.bitDepth == 10, !media.dynamicHDR else {
            throw LumaError.unsupported("Native HDR HEIC currently requires 10-bit BT.2020 PQ without known dynamic HDR.")
        }
        guard seconds.isFinite, seconds >= 0, media.duration > 0,
              seconds < media.duration else {
            throw LumaError.invalidInput("Requested HDR frame time is outside the video.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path),
              destination.pathExtension.lowercased() == "heic" else {
            throw LumaError.invalidInput("Choose a new .heic output path.")
        }
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: media.url)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .video)
            } catch {
                throw LumaError.processFailed(
                    "AVFoundation could not inspect the HEVC video track: \(error.localizedDescription)"
                )
            }
            guard let track = tracks.first else {
                throw LumaError.invalidInput("AVFoundation cannot find a video track.")
            }
            let transform: CGAffineTransform
            do {
                transform = try await track.load(.preferredTransform)
            } catch {
                throw LumaError.processFailed(
                    "AVFoundation could not load video orientation: \(error.localizedDescription)"
                )
            }
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw LumaError.processFailed(
                    "AVAssetReader initialization failed: \(error.localizedDescription)"
                )
            }
            // Ask for 10-bit Y'CbCr, not BGRA/8-bit, to avoid collapsing HDR range.
            let fullRange = ["pc", "full", "jpeg"].contains(media.colorRange)
            let format: OSType = fullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: format)]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw LumaError.unsupported("10-bit pixel output is not supported for this source.")
            }
            reader.add(output)
            let start = max(0, seconds - 2)
            let end = min(media.duration, seconds + 2)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.001, end - start), preferredTimescale: 600)
            )
            guard reader.startReading() else {
                throw LumaError.processFailed(reader.error?.localizedDescription
                                              ?? "AVAssetReader could not start 10-bit decoding.")
            }
            defer { reader.cancelReading() }
            guard let sourceColor = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else {
                throw LumaError.unsupported("BT.2100 PQ is unavailable.")
            }
            let desiredTime = CMTime(seconds: seconds, preferredTimescale: 600)
            while let sample = output.copyNextSampleBuffer() {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if CMTimeCompare(presentationTime, desiredTime) < 0 { continue }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                guard CVPixelBufferGetPixelFormatType(pixelBuffer) == format else {
                    throw LumaError.validationFailed("AVFoundation returned a different pixel format; refusing to downconvert HDR.")
                }
                let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: sourceColor])
                let oriented = image.transformed(by: transform)
                let normalized = oriented.transformed(by: CGAffineTransform(
                    translationX: -oriented.extent.minX,
                    y: -oriented.extent.minY
                ))
                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".luma-hdr-\(UUID().uuidString).heic")
                defer { try? FileManager.default.removeItem(at: temporary) }
                do {
                    try writePQ(normalized, to: temporary)
                } catch {
                    throw LumaError.processFailed(
                        "Core Image HEIF10 encoding failed after 10-bit decoding: \(error.localizedDescription)"
                    )
                }
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw LumaError.invalidInput("Destination was created by another process.")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return
            }
            throw LumaError.validationFailed(
                reader.error?.localizedDescription
                    ?? "No 10-bit frame was decoded at the requested presentation time."
            )
        }.value
    }
}
