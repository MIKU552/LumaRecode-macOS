import Foundation

public enum LumaError: LocalizedError {
    case toolsMissing(String)
    case invalidInput(String)
    case unsupported(String)
    case processFailed(String)
    case cancelled
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolsMissing(let s), .invalidInput(let s), .unsupported(let s),
             .processFailed(let s), .validationFailed(let s): return s
        case .cancelled: return "The operation was cancelled."
        }
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case hevc, avc, av1
    public var id: String { rawValue }
    public var title: String {
        switch self { case .hevc: return "HEVC"; case .avc: return "H.264"; case .av1: return "AV1" }
    }
    public var ffprobeName: String {
        switch self { case .hevc: return "hevc"; case .avc: return "h264"; case .av1: return "av1" }
    }
}

public enum EncodePurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case archive, share
    public var id: String { rawValue }
}

public enum SourceColor: String, Codable, Sendable {
    case sdr, hlg, pq, log, raw, unknown
    public var isHDR: Bool { self == .hlg || self == .pq }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public var url: URL
    public var codec: String
    public var width: Int
    public var height: Int
    public var duration: Double
    public var frameRate: Double
    public var pixelFormat: String
    public var bitDepth: Int
    public var primaries: String
    public var transfer: String
    public var matrix: String
    public var colorRange: String
    public var audioCodecs: [String]
    public var sourceColor: SourceColor
    public var dynamicHDR: Bool
    public var dynamicHDRDescription: String?
    /// Absolute ffprobe stream index, not video-stream ordinal. Handles cover art.
    public var videoStreamIndex: Int
    /// QuickTime/MP4 video sample entry, e.g. hvc1 vs hev1.
    public var codecTag: String
    /// Display Matrix rotation, as reported by ffprobe.
    public var displayRotation: Double
    /// Source mastering display / content light level metadata is not yet writable.
    public var staticHDRMetadataPresent: Bool
    /// Parsed mastering display / MaxCLL-MaxFALL; nil with present=true blocks encoding.
    public var hdrStaticMetadata: HDRStaticMetadata?
    /// FFmpeg rational timestamp time base for exact display-frame indexing.
    public var timeBase: String
    public var isInterlaced: Bool
    /// Only evidence-backed camera profiles are automatically suggested.
    public var detectedLogProfile: CameraLogProfile?

    public init(
        url: URL, codec: String, width: Int, height: Int, duration: Double,
        frameRate: Double, pixelFormat: String, bitDepth: Int, primaries: String,
        transfer: String, matrix: String, colorRange: String, audioCodecs: [String],
        sourceColor: SourceColor, dynamicHDR: Bool, dynamicHDRDescription: String? = nil,
        videoStreamIndex: Int = 0, codecTag: String = "", displayRotation: Double = 0,
        staticHDRMetadataPresent: Bool = false,
        hdrStaticMetadata: HDRStaticMetadata? = nil,
        timeBase: String = "", isInterlaced: Bool = false,
        detectedLogProfile: CameraLogProfile? = nil
    ) {
        self.url = url; self.codec = codec; self.width = width; self.height = height
        self.duration = duration; self.frameRate = frameRate; self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth; self.primaries = primaries; self.transfer = transfer
        self.matrix = matrix; self.colorRange = colorRange; self.audioCodecs = audioCodecs
        self.sourceColor = sourceColor; self.dynamicHDR = dynamicHDR
        self.dynamicHDRDescription = dynamicHDRDescription
        self.videoStreamIndex = videoStreamIndex
        self.codecTag = codecTag
        self.displayRotation = displayRotation
        self.staticHDRMetadataPresent = staticHDRMetadataPresent
        self.hdrStaticMetadata = hdrStaticMetadata
        self.timeBase = timeBase
        self.isInterlaced = isInterlaced
        self.detectedLogProfile = detectedLogProfile
    }
}

public enum SamplingChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "auto", source, yuv420 = "420", yuv422 = "422", yuv444 = "444", gray
    public var id: String { rawValue }
}
public enum BitDepthChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "auto", eight = "8", ten = "10", twelve = "12"
    public var id: String { rawValue }
}
public enum SampleRangeChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "auto", source, limited, full
    public var id: String { rawValue }
}
public enum AudioChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "auto", copy, aac, opus, flac
    public var id: String { rawValue }
}
public enum EncodingVariant: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard, fast
    public var id: String { rawValue }
}

public struct EncodeSelection: Codable, Equatable, Sendable {
    public var purpose: EncodePurpose
    public var codec: VideoCodec
    public var sampling: SamplingChoice
    public var bitDepth: BitDepthChoice
    public var colorRange: SampleRangeChoice
    public var audio: AudioChoice
    public var variant: EncodingVariant
    /// Explicit camera Log -> Rec.2100 HLG transform using original LUT.
    /// nil preserves the existing no-transform path.
    public var logProfile: CameraLogProfile?
    /// Manual interpretation is needed when camera Log metadata is absent.
    public var interpretAsLog: Bool

    public init(
        purpose: EncodePurpose = .archive, codec: VideoCodec = .hevc,
        sampling: SamplingChoice = .automatic,
        bitDepth: BitDepthChoice = .automatic,
        colorRange: SampleRangeChoice = .automatic,
        audio: AudioChoice = .automatic,
        variant: EncodingVariant = .standard,
        logProfile: CameraLogProfile? = nil,
        interpretAsLog: Bool = false
    ) {
        self.purpose = purpose
        self.codec = codec
        self.sampling = sampling
        self.bitDepth = bitDepth
        self.colorRange = colorRange
        self.audio = audio
        self.variant = variant
        self.logProfile = logProfile
        self.interpretAsLog = interpretAsLog
    }
}

public struct EncodingPlan: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let destination: URL
    public let temporary: URL
    public let selection: EncodeSelection
    public let expectedCodec: VideoCodec
    public let inputColor: SourceColor
}

public struct TranscodeProgress: Equatable, Sendable {
    public let seconds: Double
    public let duration: Double
    public let fraction: Double
    public let fps: Double?
    public init(seconds: Double, duration: Double, fps: Double?) {
        self.seconds = seconds; self.duration = duration
        self.fraction = duration > 0 ? min(1, max(0, seconds / duration)) : 0
        self.fps = fps
    }
}
