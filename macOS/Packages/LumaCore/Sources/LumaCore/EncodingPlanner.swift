import Foundation

/// A Swift planner based on Windows Transcoder.Validate/ResolveFormat and
/// recommended-presets.json, with an independent native VideoToolbox backend.
public enum EncodingPlanner {
    public static func suffix(for selection: EncodeSelection) -> String {
        selection.purpose == .archive || selection.audio == .opus ? "mkv" : "mp4"
    }

    public static func destination(
        for media: MediaInfo, selection: EncodeSelection, directory: URL
    ) -> URL {
        let marker = selection.logProfile != nil ? "HLG" : media.sourceColor.isHDR ? "HDR" : "SDR"
        let name = media.url.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(
            "\(name)_\(marker)_\(selection.codec.rawValue)_\(selection.purpose.rawValue).\(suffix(for: selection))"
        )
    }

    /// FFmpeg setparams affects frame metadata before the encoder sees it;
    /// codec/format color flags alone do not reliably write HEVC VUI.
    private static func frameTags(
        primaries: String, transfer: String, matrix: String, range: String
    ) -> String {
        var tags = ["range=\(range)"]
        if !primaries.isEmpty && primaries != "unknown" {
            tags.append("color_primaries=\(primaries)")
        }
        if !transfer.isEmpty && transfer != "unknown" {
            tags.append("color_trc=\(transfer)")
        }
        if !matrix.isEmpty && matrix != "unknown" {
            tags.append("colorspace=\(matrix)")
        }
        return "setparams=" + tags.joined(separator: ":")
    }

    private static func sourceFrameTags(_ media: MediaInfo, sourceRange: String) -> String {
        frameTags(
            primaries: media.primaries, transfer: media.transfer,
            matrix: media.matrix, range: sourceRange
        )
    }

    public static func plan(
        tools: MediaTools, media: MediaInfo,
        selection: EncodeSelection, destination: URL
    ) throws -> EncodingPlan {
        guard media.url.standardizedFileURL != destination.standardizedFileURL else {
            throw LumaError.invalidInput("Input and output must not be the same file.")
        }
        let resolved = try VideoOutputPolicy.resolve(media, selection: selection)
        // Mirror Windows Transcoder.HdrMetadata. Static HDR10 SEI is allowed
        // only on the validated software HEVC PQ path. Incomplete side data
        // and all unverified hardware/AV1/Log combinations remain blocked.
        let staticHDR: HDRStaticMetadata?
        if media.staticHDRMetadataPresent {
            guard media.sourceColor == .pq, selection.logProfile == nil,
                  selection.purpose == .archive, selection.codec == .hevc else {
                throw LumaError.unsupported(
                    "HDR10 Mastering Display / MaxCLL preservation currently requires software HEVC archiving of PQ video."
                )
            }
            guard let parsed = media.hdrStaticMetadata else {
                throw LumaError.unsupported(
                    "HDR10 metadata was detected but could not be parsed consistently. Refusing to lose it."
                )
            }
            staticHDR = parsed
        } else {
            staticHDR = nil
        }
        guard media.bitDepth <= 12 else {
            throw LumaError.unsupported(
                "Sources above 12-bit need the source-specific pipeline or explicit precision policy."
            )
        }
        if media.sourceColor.isHDR {
            guard media.primaries == "bt2020", media.matrix == "bt2020nc",
                  media.transfer == (media.sourceColor == .hlg ? "arib-std-b67" : "smpte2084") else {
                throw LumaError.unsupported(
                    "Cannot relabel HDR pixels: source color space or transfer does not match BT.2020."
                )
            }
        }
        let ext = destination.pathExtension.lowercased()
        guard ext == suffix(for: selection) else {
            throw LumaError.invalidInput("The output must use .\(suffix(for: selection)).")
        }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".luma-\(UUID().uuidString).\(ext)")
        let logConversion = selection.logProfile != nil
        let primaries = media.sourceColor.isHDR || logConversion ? "bt2020" : media.primaries
        let transfer = logConversion ? "arib-std-b67" :
            media.sourceColor.isHDR
                ? (media.sourceColor == .hlg ? "arib-std-b67" : "smpte2084")
                : media.transfer
        let matrix = media.sourceColor.isHDR || logConversion ? "bt2020nc" : media.matrix
        let rangeTag = resolved.sampleRange == "full" ? "pc" : "tv"
        let format: String
        if selection.purpose == .share {
            format = resolved.bitDepth >= 10 ? "p010le" : "nv12"
        } else {
            format = resolved.pixelFormat
        }

        var args = [
            "-hide_banner", "-nostdin", "-y", "-xerror",
            "-loglevel", "error", "-nostats", "-progress", "pipe:1",
            "-i", media.url.path,
            "-map", "0:\(media.videoStreamIndex)", "-map", "0:a?",
            "-map_metadata", logConversion ? "-1" : "0",
            "-map_chapters", "0", "-sn", "-dn"
        ]
        var filters: [String] = []
        if let profile = selection.logProfile {
            // Mirrors Transcoder.LogFilter: float RGB LUT before 16-bit HLG
            // intermediate and error-diffused output quantization.
            filters = try CameraLogPipeline.filters(media: media, profile: profile)
            if resolved.sampleRange == "full" {
                filters.append("zscale=rangein=limited:range=full:dither=error_diffusion")
            }
        } else {
            filters.append(sourceFrameTags(media, sourceRange: resolved.sourceRange))
            if resolved.sampleRange != resolved.sourceRange {
                // Pixel conversion; range metadata relabeling is insufficient.
                filters.append(
                    "zscale=rangein=\(resolved.sourceRange):range=\(resolved.sampleRange):dither=error_diffusion"
                )
            }
        }
        filters.append("format=\(format)")
        filters.append(frameTags(
            primaries: primaries, transfer: transfer,
            matrix: matrix, range: resolved.sampleRange
        ))
        args += ["-vf", filters.joined(separator: ",")]

        if selection.purpose == .archive {
            let preset = try RecommendedPresets.software(
                codec: selection.codec, fastAV1: selection.variant == .fast
            )
            args += ["-c:v", preset.encoder, "-preset", preset.preset,
                     "-crf", String(preset.quality), "-pix_fmt", format]
            let fps = media.frameRate
            if fps.isFinite && fps > 0 {
                args += ["-g", String(max(1, Int((fps * 8).rounded())))]
            }
            switch selection.codec {
            case .hevc:
                var params = [
                    "pools=16", "log-level=warning"
                ]
                for key in preset.parameters.keys.sorted() {
                    params.append("\(key)=\(preset.parameters[key]!)")
                }
                // The source's FFmpeg frame tags and color flags are preserved,
                // and macOS adds explicit VUI to prevent silent HDR relabeling.
                if !primaries.isEmpty, !transfer.isEmpty, !matrix.isEmpty,
                   !["unknown", "unspecified"].contains(primaries),
                   !["unknown", "unspecified"].contains(transfer),
                   !["unknown", "unspecified"].contains(matrix) {
                    params += [
                        "colorprim=\(primaries)",
                        "transfer=\(transfer)",
                        "colormatrix=\(matrix)"
                    ]
                }
                params.append("range=\(resolved.sampleRange == "full" ? "full" : "limited")")
                if let staticHDR {
                    params += try staticHDR.hevcParameters()
                }
                args += ["-x265-params", params.joined(separator: ":")]
            case .avc:
                let params = preset.parameters.keys.sorted().map {
                    "\($0)=\(preset.parameters[$0]!)"
                }
                if !params.isEmpty { args += ["-x264-params", params.joined(separator: ":")] }
            case .av1:
                var params = [
                    "lp=\(preset.logicalProcessors ?? 0)",
                    "tune=\(preset.tune ?? 0)"
                ]
                params += preset.parameters.keys.sorted().map {
                    "\($0)=\(preset.parameters[$0]!)"
                }
                args += ["-svtav1-params", params.joined(separator: ":")]
            }
        } else {
            // VideoToolbox is the Apple-native hardware encoder, not Intel QSV.
            let encoder = selection.codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox"
            args += [
                "-c:v", encoder,
                "-q:v", selection.codec == .hevc ? "65" : "70",
                "-allow_sw", "0"
            ]
            if selection.codec == .hevc {
                args += ["-profile:v", resolved.bitDepth >= 10 ? "main10" : "main"]
            }
            if media.frameRate.isFinite, media.frameRate > 0 {
                let gop = max(1, min(240, Int((media.frameRate * 2).rounded())))
                args += ["-g", String(gop)]
            }
        }

        if !primaries.isEmpty && primaries != "unknown" {
            args += ["-color_primaries", primaries]
        }
        if !transfer.isEmpty && transfer != "unknown" {
            args += ["-color_trc", transfer]
        }
        if !matrix.isEmpty && matrix != "unknown" {
            args += ["-colorspace", matrix]
        }
        args += ["-color_range", rangeTag]

        switch resolved.audio {
        case "copy":
            args += ["-c:a", "copy"]
        case "aac", "opus":
            let sound = try RecommendedPresets.lossyAudio(named: resolved.audio)
            args += ["-c:a", sound.encoder, "-b:a", "\(sound.bitRateKbps)k",
                     "-ac", String(sound.channels)]
            if resolved.audio == "opus" {
                args += [
                    "-ar", "48000", "-vbr", "on", "-application:a", "audio",
                    "-compression_level:a", "10"
                ]
            }
        default:
            throw LumaError.unsupported("This audio policy needs additional track validation.")
        }

        if ext == "mp4" {
            if selection.codec == .hevc { args += ["-tag:v", "hvc1"] }
            args += ["-movflags", "+faststart+write_colr"]
        }
        args += ["-fps_mode:v", "passthrough", "-enc_time_base:v", "filter", temp.path]

        return EncodingPlan(
            executable: tools.ffmpeg, arguments: args, destination: destination,
            temporary: temp, selection: selection,
            expectedCodec: selection.codec, inputColor: media.sourceColor
        )
    }
}
