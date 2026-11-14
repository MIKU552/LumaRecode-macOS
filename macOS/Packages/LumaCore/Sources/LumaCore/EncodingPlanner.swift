import Foundation

public enum EncodingPlanner {
    public static func suffix(for selection: EncodeSelection) -> String {
        selection.purpose == .archive ? "mkv" : "mp4"
    }

    public static func destination(for media: MediaInfo, selection: EncodeSelection, directory: URL) -> URL {
        let marker = media.sourceColor.isHDR ? "HDR" : "SDR"
        let name = media.url.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(
            "\(name)_\(marker)_\(selection.codec.rawValue)_\(selection.purpose.rawValue).\(suffix(for: selection))"
        )
    }

    public static func plan(
        tools: MediaTools, media: MediaInfo, selection: EncodeSelection, destination: URL
    ) throws -> EncodingPlan {
        guard media.width > 0, media.height > 0, media.url != destination else {
            throw LumaError.invalidInput("The input is invalid or matches the output path.")
        }
        guard media.sourceColor != .log, media.sourceColor != .raw, media.sourceColor != .unknown else {
            throw LumaError.unsupported("Log, RAW or unclassified color inputs require the dedicated color pipeline, which is not yet ported. No approximate conversion will be performed.")
        }
        guard !media.dynamicHDR else {
            throw LumaError.unsupported("Dolby Vision / HDR10+ metadata preservation has not been ported. Conversion is blocked to avoid silently discarding dynamic HDR metadata.")
        }
        guard media.bitDepth <= 10 || selection.purpose == .archive && selection.codec == .hevc else {
            throw LumaError.unsupported("The selected encoder cannot preserve source bit depth.")
        }
        if selection.purpose == .share && selection.codec == .av1 {
            throw LumaError.unsupported("AV1 hardware encoding is not assumed to exist on Apple Silicon. Use software Archive AV1 instead.")
        }
        let ext = destination.pathExtension.lowercased()
        guard ext == suffix(for: selection) else {
            throw LumaError.invalidInput("The output must use .\(suffix(for: selection)).")
        }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(
            ".luma-\(UUID().uuidString).\(ext)"
        )
        var a = ["-hide_banner", "-nostdin", "-y", "-xerror", "-loglevel", "error",
                 "-nostats", "-progress", "pipe:1", "-i", media.url.path,
                 "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                 "-map_chapters", "0", "-sn", "-dn"]
        let hdr = media.sourceColor.isHDR
        let depth = media.bitDepth >= 10 || hdr ? 10 : 8
        if selection.purpose == .archive {
            let encoder: String
            switch selection.codec {
            case .hevc:
                encoder = "libx265"
                a += ["-preset", "medium", "-crf", "23",
                      "-x265-params", "pools=16:log-level=warning:rdoq-level=2:psy-rdoq=1"]
            case .avc:
                encoder = "libx264"
                a += ["-preset", "medium", "-crf", "21",
                      "-x264-params", "aq-mode=2:aq-strength=0.8"]
            case .av1:
                encoder = "libsvtav1"
                a += ["-preset", "4", "-crf", "32",
                      "-svtav1-params", "tune=0:lp=0:enable-qm=1:qm-min=8:qm-max=15"]
            }
            a += ["-c:v", encoder]
        } else {
            let encoder = selection.codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox"
            a += ["-c:v", encoder, "-q:v", selection.codec == .hevc ? "65" : "70",
                  "-allow_sw", "0"]
        }
        let pixelFormat: String
        if selection.purpose == .share {
            pixelFormat = depth >= 10 ? "p010le" : "nv12"
        } else {
            // Preserve 4:2:2 / 4:4:4 only on software encoders that can express it.
            let sample = media.pixelFormat.contains("444") ? "444" :
                media.pixelFormat.contains("422") ? "422" : "420"
            let supportedSample = selection.codec == .av1 ? "420" : sample
            pixelFormat = "yuv\(supportedSample)p" + (depth > 8 ? "10le" : "")
            if media.bitDepth > 10 && selection.codec == .hevc {
                // Never silently reduce 12-bit HDR/SDR source to 10-bit.
                throw LumaError.unsupported("12-bit source archiving is pending a verified source-format and x265 capability policy.")
            }
        }
        if selection.codec == .avc && depth > 8 && selection.purpose == .share {
            throw LumaError.unsupported("VideoToolbox H.264 sharing does not promise 10-bit output. Use HEVC.")
        }
        a += ["-pix_fmt", pixelFormat]
        if hdr {
            a += ["-color_primaries", "bt2020", "-color_trc",
                  media.sourceColor == .hlg ? "arib-std-b67" : "smpte2084",
                  "-colorspace", "bt2020nc"]
        } else if media.primaries == "bt709" && media.transfer == "bt709" {
            a += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        if selection.purpose == .archive {
            a += ["-c:a", "copy"]
        } else {
            a += ["-c:a", "aac", "-b:a", "256k", "-ac", "2"]
            if selection.codec == .hevc { a += ["-tag:v", "hvc1"] }
            a += ["-movflags", "+faststart"]
        }
        a += ["-fps_mode:v", "passthrough", temp.path]
        return EncodingPlan(
            executable: tools.ffmpeg, arguments: a, destination: destination,
            temporary: temp, selection: selection,
            expectedCodec: selection.codec, inputColor: media.sourceColor
        )
    }
}
