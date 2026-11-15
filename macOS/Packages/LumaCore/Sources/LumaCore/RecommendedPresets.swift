import Foundation

/// The Windows repository's recommended-presets.json is the source of truth
/// for software encoders. QSV hardware presets are NOT used on macOS.
public struct SoftwarePreset: Equatable, Sendable {
    public let encoder: String
    public let preset: String
    public let quality: Int
    public let pixelFormat: String
    public let parameters: [String: String]
    public let tune: Int?
    public let logicalProcessors: Int?
}

public enum RecommendedPresets {
    public static func bundledJSON() throws -> Data {
        guard let url = Bundle.module.url(forResource: "recommended-presets", withExtension: "json") else {
            throw LumaError.validationFailed("Missing original Windows recommended-presets.json resource.")
        }
        return try Data(contentsOf: url)
    }

    private static func root(_ data: Data?) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data ?? bundledJSON()) as? [String: Any] else {
            throw LumaError.validationFailed("Preset JSON is not an object.")
        }
        return json
    }

    public static func software(
        codec: VideoCodec, fastAV1: Bool = false, data: Data? = nil
    ) throws -> SoftwarePreset {
        let config = try root(data)
        let value: [String: Any]?
        if fastAV1 {
            guard codec == .av1 else {
                throw LumaError.invalidInput("The fast variant is available only for archive AV1.")
            }
            value = config["archive_fast_av1"] as? [String: Any]
        } else {
            value = (config["archive"] as? [String: Any])?[codec.rawValue] as? [String: Any]
        }
        guard let section = value,
              let encoder = section["encoder"] as? String,
              let preset = section["preset"] as? String,
              let quality = section["quality"] as? Int,
              let pixelFormat = section["pixel_format"] as? String,
              let raw = section["encoder_parameters"] as? [String: Any] else {
            throw LumaError.validationFailed("Incomplete software encoding config for \(codec.rawValue).")
        }
        let expected: String
        switch codec {
        case .avc: expected = "libx264"
        case .hevc: expected = "libx265"
        case .av1: expected = "libsvtav1"
        }
        guard encoder == expected, (0...63).contains(quality) else {
            throw LumaError.validationFailed("Invalid encoder or CRF in reference config.")
        }
        var parameters: [String: String] = [:]
        for (key, value) in raw {
            guard let number = value as? NSNumber, !key.isEmpty else {
                throw LumaError.validationFailed("Non-numeric encoder parameter in reference config.")
            }
            parameters[key] = number.stringValue
        }
        return SoftwarePreset(
            encoder: encoder, preset: preset, quality: quality,
            pixelFormat: pixelFormat, parameters: parameters,
            tune: section["tune"] as? Int,
            logicalProcessors: section["lp"] as? Int
        )
    }

    public static func defaultAudio(
        purpose: EncodePurpose, codec: VideoCodec, data: Data? = nil
    ) throws -> String {
        guard let audio = try root(data)["audio"] as? [String: Any] else {
            throw LumaError.validationFailed("Missing original Windows audio config.")
        }
        if purpose == .archive {
            guard let value = audio["archive_default"] as? String else {
                throw LumaError.validationFailed("Missing archive audio default.")
            }
            return value
        }
        guard let value = (audio["share_default"] as? [String: String])?[codec.rawValue] else {
            throw LumaError.validationFailed("Missing share audio default.")
        }
        return value
    }

    public static func lossyAudio(
        named name: String, data: Data? = nil
    ) throws -> (encoder: String, bitRateKbps: Int, channels: Int) {
        guard let audio = try root(data)["audio"] as? [String: Any],
              let preset = audio[name] as? [String: Any],
              let encoder = preset["encoder"] as? String,
              let bitRate = preset["bitrate_kbps"] as? Int,
              let channels = preset["channels"] as? Int else {
            throw LumaError.unsupported("No reference audio preset for \(name).")
        }
        return (encoder, bitRate, channels)
    }
}
