import Foundation

/// Source: Windows Core/Transcoder.cs HdrMetadata / VerifyAsync.
/// ffprobe rationals are stored in real units; x265 uses 1/50000 for
/// xy chromaticity and 1/10000 cd/m² for mastering luminance.
public struct HDRStaticMetadata: Codable, Equatable, Sendable {
    public let masteringDisplay: [String: Double]?
    public let contentLight: [String: Int]?

    private static let masteringFields = [
        "green_x", "green_y", "blue_x", "blue_y", "red_x", "red_y",
        "white_point_x", "white_point_y", "max_luminance", "min_luminance"
    ]
    private static let lightFields = ["max_content", "max_average"]

    private static func number(_ raw: Any?) -> Double? {
        let string: String
        if let s = raw as? String { string = s }
        else if let n = raw as? NSNumber { string = n.stringValue }
        else { return nil }
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        let value: Double
        if parts.count == 2, let numerator = Double(parts[0]),
           let denominator = Double(parts[1]), denominator != 0 {
            value = numerator / denominator
        } else if parts.count == 1, let n = Double(string) {
            value = n
        } else {
            return nil
        }
        return value.isFinite ? value : nil
    }

    private static func mastering(_ entry: [String: Any]) -> [String: Double]? {
        var result: [String: Double] = [:]
        for key in masteringFields {
            guard let value = number(entry[key]) else { return nil }
            result[key] = value
        }
        return result
    }

    private static func light(_ entry: [String: Any]) -> [String: Int]? {
        var result: [String: Int] = [:]
        for key in lightFields {
            let raw: String
            if let s = entry[key] as? String { raw = s }
            else if let n = entry[key] as? NSNumber { raw = n.stringValue }
            else { return nil }
            guard let value = Int(raw), (0...65535).contains(value) else { return nil }
            result[key] = value
        }
        return result
    }

    /// The boolean staticHDRMetadataPresent independently tracks any SEI.
    /// If one entry is incomplete or frames disagree, parsing returns nil,
    /// and the encoder refuses to run rather than silently discarding fields.
    public static func parse(_ entries: [[String: Any]]) -> HDRStaticMetadata? {
        let masters = entries.filter {
            $0["side_data_type"] as? String == "Mastering display metadata"
        }
        let lights = entries.filter {
            $0["side_data_type"] as? String == "Content light level metadata"
        }
        guard !masters.isEmpty || !lights.isEmpty else { return nil }
        let parsedMasters = masters.compactMap(mastering)
        let parsedLights = lights.compactMap(light)
        guard parsedMasters.count == masters.count,
              parsedLights.count == lights.count else { return nil }
        guard let firstMaster = parsedMasters.first.map({ $0 }) else {
            if let firstLight = parsedLights.first,
               parsedLights.allSatisfy({ $0 == firstLight }) {
                return HDRStaticMetadata(masteringDisplay: nil, contentLight: firstLight)
            }
            return nil
        }
        guard parsedMasters.allSatisfy({
            equivalentMastering(firstMaster, $0)
        }) else { return nil }
        if let firstLight = parsedLights.first,
           !parsedLights.allSatisfy({ $0 == firstLight }) {
            return nil
        }
        return HDRStaticMetadata(
            masteringDisplay: firstMaster,
            contentLight: parsedLights.first
        )
    }

    private static func equivalentMastering(
        _ a: [String: Double], _ b: [String: Double]
    ) -> Bool {
        masteringFields.allSatisfy { key in
            guard let left = a[key], let right = b[key] else { return false }
            let unit = key.hasSuffix("luminance") ? 1.0 / 10000 : 1.0 / 50000
            return abs(left - right) <= unit + 1e-12
        }
    }

    public func equivalent(to other: HDRStaticMetadata) -> Bool {
        let matchingMaster: Bool
        switch (masteringDisplay, other.masteringDisplay) {
        case (nil, nil): matchingMaster = true
        case (let a?, let b?): matchingMaster = Self.equivalentMastering(a, b)
        default: matchingMaster = false
        }
        return matchingMaster && contentLight == other.contentLight
    }

    /// Use the exact x265 parameter names/ordering from Windows HdrMetadata.
    public func hevcParameters() throws -> [String] {
        var options = ["hdr10=1", "hdr10-opt=1", "repeat-headers=1"]
        if let md = masteringDisplay {
            func integer(_ key: String, scale: Double, maximum: Double) throws -> String {
                guard let value = md[key], value.isFinite, value >= 0,
                      value * scale <= maximum else {
                    throw LumaError.unsupported(
                        "Mastering Display coordinate or luminance is outside HEVC SEI limits."
                    )
                }
                return String(Int64((value * scale).rounded()))
            }
            let c = try Self.masteringFields.prefix(8).map {
                try integer($0, scale: 50000, maximum: 50000)
            }
            guard let maximum = md["max_luminance"],
                  let minimum = md["min_luminance"],
                  maximum > 0, minimum <= maximum else {
                throw LumaError.invalidInput("Invalid Mastering Display luminance interval.")
            }
            let high = try integer("max_luminance", scale: 10000, maximum: 4_294_967_295)
            let low = try integer("min_luminance", scale: 10000, maximum: 4_294_967_295)
            options.append(
                "master-display=G(\(c[0]),\(c[1]))B(\(c[2]),\(c[3]))"
                + "R(\(c[4]),\(c[5]))WP(\(c[6]),\(c[7]))L(\(high),\(low))"
            )
        }
        if let cl = contentLight {
            guard let maxContent = cl["max_content"], let maxAverage = cl["max_average"] else {
                throw LumaError.validationFailed("Incomplete HDR10 content light metadata.")
            }
            options.append("max-cll=\(maxContent),\(maxAverage)")
        }
        return options
    }
}
