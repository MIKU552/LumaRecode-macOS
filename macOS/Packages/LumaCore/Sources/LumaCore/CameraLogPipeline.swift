import Foundation

/// Source profiles are the actual mappings from Windows Core/Transcoder.cs,
/// not a guessed mapping from a device model, filename or video codec.
public enum CameraLogProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case pocket3, samsung, milog, applelog, applelog2
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pocket3: "DJI Pocket 3 D-Log M"
        case .samsung: "Samsung Log"
        case .milog: "Xiaomi Mi-Log"
        case .applelog: "Apple Log"
        case .applelog2: "Apple Log 2"
        }
    }

    public var fileName: String {
        switch self {
        case .pocket3: "DJI_Osmo_DLogM_to_Rec2100_HLG_BT2408_Neutral.cube"
        case .samsung: "Samsung_Log_to_Rec2100_HLG.cube"
        case .milog: "REDMI_K90_MiLog_to_Rec2100_HLG.cube"
        case .applelog: "Apple_Log_to_Rec2100_HLG.cube"
        case .applelog2: "Apple_Log_2_to_Rec2100_HLG.cube"
        }
    }

    /// YCbCr decoding matrix, NOT the camera's scene-linear RGB primaries.
    public var fallbackMatrix: String {
        self == .pocket3 ? "709" : "2020_ncl"
    }

    public var fallbackRange: String {
        self == .milog ? "full" : "limited"
    }
}

/// Camera Log conversion preserves the original high-precision floating-point
/// LUT workflow and color-metadata order. FFmpeg is user-installed and external.
public enum CameraLogPipeline {
    public static func bundledURL(for profile: CameraLogProfile) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: String(profile.fileName.dropLast(".cube".count)),
            withExtension: "cube"
        ), FileManager.default.isReadableFile(atPath: url.path) else {
            throw LumaError.toolsMissing(
                "The tested \(profile.title) LUT is missing from the application resources."
            )
        }
        return url
    }

    /// The original unmodified Pocket 3 LUT is Apache-2.0, unlike the
    /// four project-generated MIT LUTs. Preserve the upstream text in the
    /// distributed LumaCore resource bundle, not only in the source repo.
    public static func openOSVAttributions() throws -> (license: URL, notice: URL) {
        guard let license = Bundle.module.url(forResource: "OpenOSV-LICENSE", withExtension: "txt"),
              let notice = Bundle.module.url(forResource: "OpenOSV-NOTICE", withExtension: "txt"),
              FileManager.default.isReadableFile(atPath: license.path),
              FileManager.default.isReadableFile(atPath: notice.path) else {
            throw LumaError.validationFailed(
                "OpenOSV Apache-2.0 license or attribution notice is missing from the app bundle."
            )
        }
        return (license, notice)
    }

    public static func decodingMatrix(
        media: MediaInfo, profile: CameraLogProfile
    ) -> String {
        switch media.matrix.lowercased() {
        case "gbr": "gbr"
        case "bt709": "709"
        case "bt2020nc": "2020_ncl"
        case "smpte170m": "170m"
        case "bt470bg": "470bg"
        default: profile.fallbackMatrix
        }
    }

    public static func decodingRange(
        media: MediaInfo, profile: CameraLogProfile
    ) -> String {
        switch media.colorRange.lowercased() {
        case "pc", "full", "jpeg": "full"
        case "tv", "limited", "mpeg": "limited"
        default: profile.fallbackRange
        }
    }

    /// Escape paths before inserting them into an FFmpeg filtergraph.
    /// The outer filtergraph removes one escaping layer; the lut3d option
    /// parser then reads the literal filename.
    private static func escapedFilterPath(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw LumaError.invalidInput("Unsafe camera LUT resource path.")
        }
        // Double escape separators for both FFmpeg filtergraph levels.
        var escaped = ""
        for c in value {
            switch c {
            case "\\", ":", ",", ";", "[", "]", "'":
                escaped += "\\\\\\"
                escaped.append(c)
            case " ":
                escaped += "\\ "
            default:
                escaped.append(c)
            }
        }
        return escaped
    }

    /// Returns the exact source-style Log->HLG conversion stages, leaving
    /// output sampling/range/bit depth to the main planner.
    public static func filters(
        media: MediaInfo, profile: CameraLogProfile,
        resource: URL? = nil
    ) throws -> [String] {
        let lutURL = try resource ?? bundledURL(for: profile)
        guard lutURL.isFileURL else {
            throw LumaError.invalidInput("Camera LUT must be an on-disk file.")
        }
        let path = try escapedFilterPath(lutURL.path)
        let inputMatrix = decodingMatrix(media: media, profile: profile)
        let inputRange = decodingRange(media: media, profile: profile)

        var result: [String] = []
        if ["gbr", "gbrpf32le", "gbrp16le"].contains(where: {
            media.pixelFormat.lowercased().hasPrefix($0)
        }) {
            result.append("format=gbrpf32le")
        }
        result += [
            "zscale=matrixin=\(inputMatrix):rangein=\(inputRange):range=full",
            "format=gbrpf32le",
            "lut3d=file=\(path):interp=tetrahedral",
            "setparams=range=full:color_primaries=bt2020:color_trc=arib-std-b67:colorspace=gbr",
            "zscale=matrix=2020_ncl:rangein=full:range=limited:dither=error_diffusion",
            "format=yuv444p16le"
        ]
        return result
    }
}
