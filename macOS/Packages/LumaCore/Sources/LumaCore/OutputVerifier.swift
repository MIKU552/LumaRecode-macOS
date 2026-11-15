import Foundation

/// Verifies the encoded file before publication. Porting reference:
/// Windows Core/Transcoder.cs VerifyAsync and Core/OutputPolicy.cs.
/// A successful FFmpeg exit status does not mean the result is correct.
public enum OutputVerifier {
    public static func verify(
        source: MediaInfo, encoded: MediaInfo, plan: EncodingPlan
    ) throws {
        let selected = plan.selection
        let format = try VideoOutputPolicy.resolve(source, selection: selected)
        func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            if !ok() { throw LumaError.validationFailed(message) }
        }

        try require(encoded.codec == plan.expectedCodec.ffprobeName,
                    "Video codec differs from the requested \(plan.expectedCodec.title).")
        let normalizedPixelFormat = encoded.pixelFormat
            .replacingOccurrences(of: "yuvj", with: "yuv")
        let expectedPixelFormat = format.pixelFormat
        try require(
            normalizedPixelFormat == expectedPixelFormat ||
                (format.sampling == "gray" && normalizedPixelFormat.hasPrefix("gray")
                    && encoded.bitDepth == format.bitDepth),
            "Output pixel format \(encoded.pixelFormat) does not match \(expectedPixelFormat)."
        )
        try require(encoded.bitDepth == format.bitDepth,
                    "Output precision \(encoded.bitDepth)-bit does not match \(format.bitDepth)-bit.")

        let turns = abs(source.displayRotation.truncatingRemainder(dividingBy: 180))
        let rotated = abs(turns - 90) < 1
        let expectedWidth = rotated ? source.height : source.width
        let expectedHeight = rotated ? source.width : source.height
        try require(encoded.width == expectedWidth && encoded.height == expectedHeight,
                    "Output picture size \(encoded.width)×\(encoded.height) differs from expected "
                    + "\(expectedWidth)×\(expectedHeight) (including Display Matrix rotation).")

        let desiredRange = format.sampleRange == "full" ? "pc" : "tv"
        let actualRange = canonicalRange(encoded.colorRange)
        try require(actualRange == desiredRange,
                    "Output sample range \(encoded.colorRange) does not match \(desiredRange).")

        if selected.logProfile == nil {
            // Camera Log conversion intentionally changes transfer, matrix and
            // primaries; comparing source Log tags against HLG would be wrong.
            for (label, sourceValue, finalValue) in [
                ("color primaries", source.primaries, encoded.primaries),
                ("transfer function", source.transfer, encoded.transfer),
                ("color matrix", source.matrix, encoded.matrix)
            ] where isSpecified(sourceValue) {
                try require(sourceValue == finalValue,
                            "Output \(label) \(finalValue) differs from source \(sourceValue).")
            }
        }
        let expectedColor: SourceColor = selected.logProfile == nil
            ? source.sourceColor : .hlg
        if expectedColor.isHDR {
            try require(encoded.sourceColor == expectedColor
                && encoded.primaries == "bt2020"
                && encoded.matrix == "bt2020nc"
                && encoded.bitDepth >= 10,
                "Output no longer carries the expected BT.2020 HDR transfer / 10-bit signal.")
        } else {
            try require(encoded.sourceColor == .sdr,
                        "Output no longer carries valid SDR transfer metadata.")
            try require(!encoded.dynamicHDR && !encoded.staticHDRMetadataPresent,
                        "SDR output contains unexpected HDR metadata.")
        }

        try require(!encoded.dynamicHDR,
                    "Output unexpectedly contains dynamic HDR metadata.")
        if source.staticHDRMetadataPresent {
            // FFprobe reports SI rational values. Compare within one target
            // HEVC SEI quantization step (1/50000 chroma, 1/10000 cd/m²).
            guard let expected = source.hdrStaticMetadata,
                  let actual = encoded.hdrStaticMetadata else {
                throw LumaError.validationFailed(
                    "Source or output HDR10 Mastering Display / MaxCLL metadata is missing or incomplete."
                )
            }
            try require(encoded.staticHDRMetadataPresent && expected.equivalent(to: actual),
                        "Encoded HDR10 mastering display or content light values differ from the source.")
        }
        let sourceAudio = source.audioCodecs
        let outputAudio = encoded.audioCodecs
        try require(sourceAudio.count == outputAudio.count,
                    "Output audio track count differs from source (\(sourceAudio.count) → \(outputAudio.count)).")
        switch format.audio {
        case "copy":
            try require(sourceAudio == outputAudio,
                        "Copied audio tracks changed codec or order.")
        case "aac":
            try require(outputAudio.allSatisfy { $0 == "aac" },
                        "AAC conversion produced non-AAC audio.")
        case "opus":
            try require(outputAudio.allSatisfy { $0 == "opus" },
                        "Opus conversion produced non-Opus audio.")
        default:
            throw LumaError.validationFailed("Audio verification is not implemented for \(format.audio).")
        }

        if plan.destination.pathExtension.lowercased() == "mp4"
            && selected.codec == .hevc {
            try require(encoded.codecTag == "hvc1",
                        "Apple-compatible HEVC MP4 must use hvc1, got \(encoded.codecTag).")
        }
    }

    private static func canonicalRange(_ input: String) -> String {
        switch input.lowercased() {
        case "full", "pc", "jpeg": return "pc"
        case "limited", "tv", "mpeg": return "tv"
        default: return input
        }
    }

    private static func isSpecified(_ value: String) -> Bool {
        !value.isEmpty && !["unknown", "unspecified", "N/A"].contains(value)
    }
}
