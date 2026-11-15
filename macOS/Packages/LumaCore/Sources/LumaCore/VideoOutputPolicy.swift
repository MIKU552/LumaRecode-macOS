import Foundation

/// Direct port of source-dependent constraints in Windows Core/OutputPolicy.cs
/// and Transcoder.ResolveFormat (not a generic video preset heuristic).
public struct ResolvedVideoFormat: Sendable, Equatable {
    public let sampling: String
    public let bitDepth: Int
    public let sampleRange: String
    public let sourceRange: String
    public let pixelFormat: String
    public let audio: String
}

public enum VideoOutputPolicy {
    private struct ChromaShift {
        let width: Int
        let height: Int
    }
    private static let shifts: [String: ChromaShift] = [
        "444": ChromaShift(width: 0, height: 0),
        "422": ChromaShift(width: 1, height: 0),
        "420": ChromaShift(width: 1, height: 1),
        "440": ChromaShift(width: 0, height: 1),
        "411": ChromaShift(width: 2, height: 0),
        "410": ChromaShift(width: 2, height: 2)
    ]

    public static func sourceSampling(_ media: MediaInfo) -> String? {
        let p = media.pixelFormat.lowercased()
        if p.hasPrefix("gray") || p.hasPrefix("ya") { return "gray" }
        if p.hasPrefix("rgb") || p.hasPrefix("bgr") || p.hasPrefix("gbr")
            || p.hasPrefix("argb") || p.hasPrefix("abgr")
            || p.hasPrefix("rgba") || p.hasPrefix("bgra") || p == "pal8" {
            return "444"
        }
        if ["nv12", "nv21", "p010le", "p012le", "p016le"].contains(p) {
            return "420"
        }
        for format in ["420", "422", "444", "440", "411", "410"] where p.contains(format) {
            return format
        }
        return nil
    }

    public static func sourceRange(_ media: MediaInfo) -> String {
        switch media.colorRange.lowercased() {
        case "pc", "full", "jpeg": return "full"
        case "tv", "limited", "mpeg": return "limited"
        default:
            let p = media.pixelFormat.lowercased()
            return p.hasPrefix("rgb") || p.hasPrefix("gbr") || p.hasPrefix("bgr")
                || p.hasPrefix("yuvj") ? "full" : "limited"
        }
    }

    public static func supportedSampling(_ media: MediaInfo) -> [String] {
        guard let from = sourceSampling(media) else { return [] }
        if from == "gray" { return ["gray", "420"] }
        guard let source = shifts[from] else { return [] }
        return ["420", "422", "444"].filter { choice in
            guard let to = shifts[choice] else { return false }
            return to.width >= source.width && to.height >= source.height
        }
    }

    public static func supportedDepths(_ media: MediaInfo, selection: EncodeSelection) -> [Int] {
        let maximum = max(8, media.bitDepth)
        let caps = selection.purpose == .share && selection.codec == .avc ? [8] :
            selection.purpose == .archive && selection.codec == .hevc ? [8, 10, 12] : [8, 10]
        return caps.filter {
            $0 <= maximum && (!(media.sourceColor.isHDR || selection.logProfile != nil) || $0 >= 10)
        }
    }

    public static func resolve(_ media: MediaInfo, selection: EncodeSelection) throws -> ResolvedVideoFormat {
        let logConversion = selection.logProfile != nil
        if logConversion {
            guard media.sourceColor == .log
                || (selection.interpretAsLog && [.sdr, .unknown].contains(media.sourceColor)) else {
                throw LumaError.invalidInput(
                    "Select the actual camera Log source, or explicitly enable manual Log interpretation."
                )
            }
            guard selection.purpose == .archive && selection.codec != .avc else {
                throw LumaError.unsupported(
                    "Camera Log -> HLG is initially supported by software HEVC / AV1 archiving only."
                )
            }
            guard media.bitDepth >= 10 else {
                throw LumaError.unsupported("The original camera Log LUT pipeline requires a 10-bit or higher source.")
            }
        } else {
            guard [.sdr, .hlg, .pq].contains(media.sourceColor) else {
                throw LumaError.unsupported(
                    "Camera Log requires a selected original camera LUT; RAW/unknown need their own processing."
                )
            }
        }
        guard !media.dynamicHDR else {
            throw LumaError.unsupported("Dolby Vision and HDR10+ per-frame metadata preservation is not yet ported.")
        }
        guard media.width > 0, media.height > 0, media.bitDepth > 0 else {
            throw LumaError.invalidInput("Invalid picture size or pixel precision.")
        }
        guard !((media.sourceColor.isHDR || logConversion) && selection.codec == .avc) else {
            throw LumaError.unsupported("HDR output requires HEVC or AV1, as in Windows ResolveFormat.")
        }
        guard !(selection.purpose == .share && selection.codec == .av1) else {
            throw LumaError.unsupported("VideoToolbox AV1 encoding is not available as a validated Mac hardware mode.")
        }
        guard selection.variant == .standard ||
                (selection.purpose == .archive && selection.codec == .av1) else {
            throw LumaError.invalidInput("Fast backup preset is for software archive AV1 only.")
        }
        let permitted = supportedSampling(media)
        guard !permitted.isEmpty else {
            throw LumaError.unsupported("Source pixel sampling is not understood; refusing an unverified chroma conversion.")
        }
        let sampling: String
        switch selection.sampling {
        case .automatic:
            let from = sourceSampling(media)!
            if selection.purpose == .share || selection.codec == .av1 || from == "440" {
                sampling = "420"
            } else {
                sampling = from
            }
        case .source:
            let p = media.pixelFormat.lowercased()
            guard !p.hasPrefix("yuva") && !p.hasPrefix("gbrap") else {
                throw LumaError.unsupported("Source sampling with alpha requires explicit alpha removal.")
            }
            sampling = sourceSampling(media)!
        default: sampling = selection.sampling.rawValue
        }
        guard permitted.contains(sampling) else {
            throw LumaError.unsupported("Output sampling exceeds source chroma resolution or encoder constraints.")
        }
        guard sampling == "420" ||
                (selection.purpose == .archive && selection.codec != .av1) else {
            throw LumaError.unsupported("Only software H.264/HEVC archiving can preserve 4:2:2 or 4:4:4.")
        }
        let depths = supportedDepths(media, selection: selection)
        guard !depths.isEmpty else {
            throw LumaError.unsupported("HDR requires a 10-bit source, and the requested encoder cannot preserve it.")
        }
        let depth: Int
        if selection.bitDepth == .automatic {
            depth = selection.purpose == .archive ? depths.max()! :
                (media.sourceColor.isHDR || logConversion) ? 10 : 8
        } else {
            depth = Int(selection.bitDepth.rawValue) ?? 0
        }
        guard depths.contains(depth) else {
            throw LumaError.invalidInput("Output bit depth exceeds source precision or encoder capabilities.")
        }
        let inputRange: String
        if let profile = selection.logProfile {
            inputRange = CameraLogPipeline.decodingRange(media: media, profile: profile)
        } else {
            inputRange = sourceRange(media)
        }
        let range: String
        switch selection.colorRange {
        case .automatic:
            range = selection.purpose == .archive ? inputRange : "limited"
        case .source: range = inputRange
        case .limited: range = "limited"
        case .full: range = "full"
        }
        let pix = sampling == "gray" ? (depth > 8 ? "gray\(depth)le" : "gray") :
            "yuv\(sampling)p" + (depth > 8 ? "\(depth)le" : "")

        let defaultAudio = try RecommendedPresets.defaultAudio(purpose: selection.purpose, codec: selection.codec)
        let audio = selection.audio == .automatic ? defaultAudio : selection.audio.rawValue
        guard ["copy", "aac", "opus"].contains(audio) else {
            throw LumaError.unsupported("FLAC needs original lossless-track validation, which is not yet ported.")
        }
        return ResolvedVideoFormat(
            sampling: sampling, bitDepth: depth, sampleRange: range,
            sourceRange: inputRange, pixelFormat: pix, audio: audio
        )
    }
}
