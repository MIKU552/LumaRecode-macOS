import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import LumaCore
import Photos

/// Creates actual Apple Live Photo pair resources, not Google's Motion Photo.
///
/// Initial supported source is tagged SDR/8-bit movie. Apple frameworks
/// perform the trim and write JPEG/MOV; no FFmpeg binaries are bundled.
/// Photos-library import is a separate explicit user action.
public enum AppleLivePhotoExporter {
    private static let stillIdentifier = "mdta/com.apple.quicktime.still-image-time"

    public static func export(
        from source: MediaInfo,
        selectedTime: Double,
        to directory: URL,
        name: String
    ) async throws -> LivePhotoPair {
        guard source.sourceColor == .sdr, source.bitDepth == 8,
              !source.dynamicHDR, !source.staticHDRMetadataPresent,
              ["h264", "hevc"].contains(source.codec) else {
            throw LumaError.unsupported(
                "Native Live Photo currently requires an 8-bit SDR H.264/HEVC video "
                + "without HDR metadata; it will not silently convert HDR."
            )
        }
        guard directory.isFileURL, !name.isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.contains("\n"), !name.contains("\0") else {
            throw LumaError.invalidInput("Live Photo destination name must be a simple filename.")
        }
        let window = try LivePhotoWindow.resolve(
            duration: source.duration, selectedTime: selectedTime
        )
        let stillDestination = directory.appendingPathComponent(name + ".jpg")
        let movieDestination = directory.appendingPathComponent(name + ".mov")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: stillDestination.path),
              !fm.fileExists(atPath: movieDestination.path) else {
            throw LumaError.invalidInput(
                "Live Photo JPEG or MOV already exists. Choose a different basename."
            )
        }

        let identifier = UUID()
        let temporary = directory.appendingPathComponent(".luma-live-\(identifier.uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let trim = temporary.appendingPathComponent("clip.mov")
        let photo = temporary.appendingPathComponent("still.jpg")
        let movie = temporary.appendingPathComponent("paired.mov")
        let created = try await create(
            from: source.url, window: window,
            identifier: identifier, clip: trim, still: photo, movie: movie
        )
        try await LivePhotoPairVerifier.verify(
            still: photo, movie: movie, expectedIdentifier: identifier.uuidString,
            expectedStillTime: created
        )
        try Task.checkCancellation()
        guard !fm.fileExists(atPath: stillDestination.path),
              !fm.fileExists(atPath: movieDestination.path) else {
            throw LumaError.invalidInput("An output file was created during Live Photo export.")
        }
        try fm.moveItem(at: movie, to: movieDestination)
        do {
            try fm.moveItem(at: photo, to: stillDestination)
        } catch {
            try? fm.removeItem(at: movieDestination)
            throw error
        }
        return LivePhotoPair(
            still: stillDestination, movie: movieDestination,
            identifier: identifier.uuidString, stillTime: created
        )
    }

    private static func create(
        from url: URL, window: LivePhotoWindow,
        identifier: UUID, clip: URL, still: URL, movie: URL
    ) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LumaError.unsupported("AVFoundation cannot export this source as a Live Photo movie.")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 60000),
            duration: CMTime(seconds: window.duration, preferredTimescale: 60000)
        )
        try await session.export(to: clip, as: .mov)
        try Task.checkCancellation()
        let clipped = AVURLAsset(url: clip)
        let generator = AVAssetImageGenerator(asset: clipped)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(
            at: CMTime(seconds: window.stillTime, preferredTimescale: 60000)
        )
        let posterTime = CMTimeGetSeconds(frame.actualTime)
        guard posterTime.isFinite, posterTime >= 0 else {
            throw LumaError.validationFailed("Apple image generator returned an invalid still timestamp.")
        }
        try LivePhotoStillMetadata.writeJPEG(
            frame.image, identifier: identifier, to: still
        )
        try await writePairedMovie(
            from: clipped, identifier: identifier.uuidString,
            stillTime: frame.actualTime, destination: movie
        )
        return posterTime
    }

    /// Repackages the already trimmed, compatible QuickTime movie without
    /// deliberately changing video sample data. Writes both the top-level
    /// content ID and Apple timed metadata track.
    private static func writePairedMovie(
        from asset: AVURLAsset, identifier: String,
        stillTime: CMTime, destination: URL
    ) async throws {
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard let video = videos.first else {
            throw LumaError.invalidInput("The trimmed Live Photo has no video track.")
        }
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(url: destination, fileType: .mov)
        let trackOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw LumaError.unsupported("Cannot read the encoded Live Photo movie samples.")
        }
        reader.add(trackOutput)
        let videoFormats = try await video.load(.formatDescriptions)
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormats.first
        )
        videoInput.transform = try await video.load(.preferredTransform)
        guard writer.canAdd(videoInput) else {
            throw LumaError.unsupported("Cannot write the paired Live Photo video stream.")
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let track = audios.first {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let formats = try await track.load(.formatDescriptions)
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first
            )
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
        }

        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.identifier = .quickTimeMetadataContentIdentifier
        contentIdentifier.value = identifier as NSString
        contentIdentifier.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [contentIdentifier]

        let specification: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                stillIdentifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                "com.apple.metadata.datatype.int8"
        ]
        var formatDescription: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw LumaError.processFailed("Could not define the Apple still-image-time metadata track.")
        }
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription
        )
        guard writer.canAdd(metadataInput) else {
            throw LumaError.unsupported("QuickTime cannot add the Live Photo timed metadata track.")
        }
        let metadataReceiver = writer.inputMetadataReceiver(for: metadataInput)
        let imageTime = AVMutableMetadataItem()
        imageTime.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        imageTime.key = "com.apple.quicktime.still-image-time" as NSString
        imageTime.value = NSNumber(value: 0)
        imageTime.dataType = "com.apple.metadata.datatype.int8"
        let timedGroup = AVTimedMetadataGroup(
            items: [imageTime],
            timeRange: CMTimeRange(
                start: stillTime, duration: CMTime(value: 1, timescale: 600)
            )
        )

        guard reader.startReading() else {
            throw LumaError.processFailed(reader.error?.localizedDescription
                                          ?? "Live Photo MOV reader could not start.")
        }
        do {
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            try await metadataReceiver.append(timedGroup)
            metadataReceiver.finish()

            // Interleave compressed video and audio samples by their source
            // decode timestamps. Feeding three seconds of video before
            // writing any audio can deadlock AVAssetWriter's muxing buffers.
            try await copyInterleaved(
                videoOutput: trackOutput, videoInput: videoInput,
                audioOutput: audioOutput, audioInput: audioInput, writer: writer
            )
            guard reader.status == .completed else {
                throw LumaError.processFailed(
                    reader.error?.localizedDescription ?? "Live Photo media reader did not finish."
                )
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw LumaError.processFailed(
                    writer.error?.localizedDescription ?? "Apple Live Photo MOV writer failed."
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    /// Write samples in decode timestamp order, preserving B-frame DTS.
    private static func copyInterleaved(
        videoOutput: AVAssetReaderTrackOutput, videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?, writer: AVAssetWriter
    ) async throws {
        var video = videoOutput.copyNextSampleBuffer()
        var audio = audioOutput?.copyNextSampleBuffer()
        var videoCount = 0
        var audioCount = 0

        func decodeTime(_ sample: CMSampleBuffer) -> CMTime {
            let dts = CMSampleBufferGetDecodeTimeStamp(sample)
            return dts.isValid ? dts : CMSampleBufferGetPresentationTimeStamp(sample)
        }
        while video != nil || audio != nil {
            try Task.checkCancellation()
            let writeVideo: Bool
            switch (video, audio) {
            case (nil, nil): break
            case (_?, nil): writeVideo = true
            case (nil, _?): writeVideo = false
            case (let v?, let a?):
                writeVideo = CMTimeCompare(decodeTime(v), decodeTime(a)) <= 0
            }
            if writeVideo, let sample = video {
                try await append(sample, to: videoInput, writer: writer)
                videoCount += 1
                video = videoOutput.copyNextSampleBuffer()
            } else if let sample = audio, let audioInput {
                try await append(sample, to: audioInput, writer: writer)
                audioCount += 1
                audio = audioOutput?.copyNextSampleBuffer()
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        guard videoCount > 0, audioOutput == nil || audioCount > 0 else {
            throw LumaError.validationFailed(
                "Live Photo movie has empty video or selected audio track."
            )
        }
    }

    private static func append(
        _ sample: CMSampleBuffer, to input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw LumaError.processFailed(
                    writer.error?.localizedDescription ?? "Live Photo writer stopped accepting samples."
                )
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard input.append(sample) else {
            throw LumaError.processFailed(
                writer.error?.localizedDescription ?? "Live Photo could not append a media sample."
            )
        }
    }
}

/// Validates the actual stored assets, not merely the parameters sent to
/// ImageIO and AVAssetWriter. Photo-library import is not done here.
public enum LivePhotoPairVerifier {
    public static func verify(
        still: URL, movie: URL,
        expectedIdentifier: String, expectedStillTime: Double
    ) async throws {
        let actualStill = try LivePhotoStillMetadata.identifier(in: still)
        guard actualStill == expectedIdentifier else {
            throw LumaError.validationFailed("Live Photo JPEG asset identifier mismatch.")
        }
        let asset = AVURLAsset(url: movie)
        let movieMetadata = try await asset.load(.metadata)
        var matchedContentID = false
        for item in movieMetadata where item.identifier == .quickTimeMetadataContentIdentifier {
            if try await item.load(.stringValue) == expectedIdentifier {
                matchedContentID = true
            }
        }
        guard matchedContentID else {
            throw LumaError.validationFailed("Live Photo MOV content identifier is missing or mismatched.")
        }
        let video = try await asset.loadTracks(withMediaType: .video)
        guard !video.isEmpty else {
            throw LumaError.validationFailed("Live Photo MOV has no video samples.")
        }
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard !tracks.isEmpty else {
            throw LumaError.validationFailed("Live Photo MOV has no timed still-image metadata track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        guard reader.canAdd(output) else {
            throw LumaError.validationFailed("Cannot inspect Live Photo metadata track.")
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        guard reader.startReading() else {
            throw LumaError.validationFailed("Cannot decode Live Photo timed metadata.")
        }
        defer { reader.cancelReading() }
        var matchingTime = false
        while let group = adaptor.nextTimedMetadataGroup() {
            if group.items.contains(where: {
                $0.keySpace?.rawValue == "mdta"
                    && ($0.key as? String) == "com.apple.quicktime.still-image-time"
            }) {
                let position = CMTimeGetSeconds(group.timeRange.start)
                if abs(position - expectedStillTime) <= 0.05 {
                    matchingTime = true
                }
            }
        }
        guard matchingTime else {
            throw LumaError.validationFailed(
                "Live Photo still-image-time was missing or not aligned with the JPEG poster."
            )
        }
    }
}
