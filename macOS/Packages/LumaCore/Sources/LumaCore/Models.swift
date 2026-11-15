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

    public init(
        url: URL, codec: String, width: Int, height: Int, duration: Double,
        frameRate: Double, pixelFormat: String, bitDepth: Int, primaries: String,
        transfer: String, matrix: String, colorRange: String, audioCodecs: [String],
        sourceColor: SourceColor, dynamicHDR: Bool, dynamicHDRDescription: String? = nil
    ) {
        self.url = url; self.codec = codec; self.width = width; self.height = height
        self.duration = duration; self.frameRate = frameRate; self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth; self.primaries = primaries; self.transfer = transfer
        self.matrix = matrix; self.colorRange = colorRange; self.audioCodecs = audioCodecs
        self.sourceColor = sourceColor; self.dynamicHDR = dynamicHDR
        self.dynamicHDRDescription = dynamicHDRDescription
    }
}

public struct EncodeSelection: Codable, Equatable, Sendable {
    public var purpose: EncodePurpose
    public var codec: VideoCodec
    public init(purpose: EncodePurpose = .archive, codec: VideoCodec = .hevc) {
        self.purpose = purpose; self.codec = codec
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
