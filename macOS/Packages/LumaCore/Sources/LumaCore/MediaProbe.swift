import Foundation

/// Native Swift ffprobe adapter. Selection, first-frame tag fallback and
/// attached-picture handling are based on Windows Core/MediaProbe.cs.
public enum MediaProbe {
    private static func string(_ object: [String: Any], _ name: String) -> String {
        if let value = object[name] as? String { return value }
        if let value = object[name] as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ object: [String: Any], _ name: String) -> Int {
        Int(string(object, name)) ?? 0
    }

    private static func number(_ value: String) -> Double {
        let pieces = value.split(separator: "/")
        if pieces.count == 2, let n = Double(pieces[0]), let d = Double(pieces[1]), d != 0 {
            return n / d
        }
        return Double(value) ?? 0
    }

    private static func isUnspecified(_ value: String) -> Bool {
        value.isEmpty || value == "unknown" || value == "unspecified" || value == "N/A"
    }

    private static func mediaStream(_ streams: [[String: Any]]) -> (offset: Int, video: [String: Any])? {
        let candidates = streams.enumerated().filter { _, stream in
            guard string(stream, "codec_type") == "video" else { return false }
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            return int(disposition, "attached_pic") == 0
        }
        // ProRes RAW is an explicitly preferred video track in the Windows probe.
        if let raw = candidates.first(where: { string($0.element, "codec_name") == "prores_raw" }) {
            return (raw.offset, raw.element)
        }
        guard let selected = candidates.first else { return nil }
        return (selected.offset, selected.element)
    }

    public static func parse(_ data: Data, url: URL) throws -> MediaInfo {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = doc["streams"] as? [[String: Any]],
              let (offset, video) = mediaStream(streams) else {
            throw LumaError.invalidInput("No playable video stream was found.")
        }
        let audio = streams.filter { string($0, "codec_type") == "audio" }
            .map { string($0, "codec_name") }
        let format = doc["format"] as? [String: Any] ?? [:]
        let firstFrames = doc["frames"] as? [[String: Any]] ?? []
        func field(_ name: String) -> String {
            let fromStream = string(video, name)
            guard isUnspecified(fromStream) else { return fromStream }
            return firstFrames.map { string($0, name) }.first(where: { !isUnspecified($0) }) ?? fromStream
        }

        let transfer = field("color_transfer")
        let primaries = field("color_primaries")
        let matrix = field("color_space")
        let range = field("color_range")
        let pixel = string(video, "pix_fmt")
        let codec = string(video, "codec_name")
        let profile = string(video, "profile").lowercased()
        let streamTags = video["tags"] as? [String: Any] ?? [:]
        let formatTags = format["tags"] as? [String: Any] ?? [:]
        let tags = formatTags.merging(streamTags) { _, stream in stream }
        let raw = codec == "prores_raw" || (codec == "prores" && profile.contains("raw"))
        // Use exactly the same evidence-based keys as the Windows Classify
        // logic. A device name, codec or .MOV suffix never proves a Log curve.
        let lowered = Dictionary(uniqueKeysWithValues: tags.map {
            ($0.key.lowercased(), string(tags, $0.key).lowercased())
        })
        let appleLogKeys = [
            "com.apple.proapps.logcolorspace",
            "com.apple.proapps.color.logcolorspace"
        ]
        let appleLogValues = appleLogKeys.compactMap { lowered[$0] }
        let detected: CameraLogProfile?
        if appleLogValues.contains("com.apple.apple-wide-gamut.apple-log") {
            detected = .applelog2
        } else if appleLogValues.contains("com.apple.log.apple-log") {
            detected = .applelog
        } else if ["1", "true", "yes"].contains(lowered["com.xiaomi.record_log"] ?? "") {
            detected = .milog
        } else if let samsung = lowered["com.samsung.android.logvideo"],
                  !samsung.isEmpty && !["0", "false", "no"].contains(samsung) {
            detected = .samsung
        } else {
            detected = nil
        }
        let genericLog = lowered.contains { key, value in
            let keyHints = ["log", "colorgamma", "color_mode", "colormode", "gamma"]
            return keyHints.contains(where: { key.contains($0) })
                && value.contains("log")
                && !value.contains("catalog")
        }
        let isLog = detected != nil || genericLog

        let color: SourceColor
        if raw { color = .raw }
        else if isLog { color = .log }
        else if transfer == "arib-std-b67" { color = .hlg }
        else if transfer == "smpte2084" { color = .pq }
        else if ["bt709", "iec61966-2-1", "smpte170m", "bt470bg"].contains(transfer) {
            color = .sdr
        } else {
            color = .unknown
        }

        let streamSideData = video["side_data_list"] as? [[String: Any]] ?? []
        let frameSideData = firstFrames.flatMap { $0["side_data_list"] as? [[String: Any]] ?? [] }
        let evidence = (streamSideData + frameSideData)
            .map { string($0, "side_data_type") }.joined(separator: " ")
        let codecTag = string(video, "codec_tag_string").lowercased()
        let metadataNames = (streamSideData + frameSideData)
            .map { string($0, "side_data_type") }
        let hasStaticMetadata = metadataNames.contains("Mastering display metadata")
            || metadataNames.contains("Content light level metadata")
        let hdrMetadata = hasStaticMetadata
            ? HDRStaticMetadata.parse(streamSideData + frameSideData) : nil
        let display = streamSideData.first {
            string($0, "side_data_type") == "Display Matrix"
        }
        let displayRotation = number(display.map { string($0, "rotation") } ?? "")
        let tagRotation = number(string(tags, "rotate"))
        let interlaced = ["tt", "bb", "tb", "bt"].contains(string(video, "field_order"))
            || firstFrames.contains { int($0, "interlaced_frame") == 1 }
        let dynamicHDR = evidence.localizedCaseInsensitiveContains("DOVI")
            || evidence.localizedCaseInsensitiveContains("Dolby Vision")
            || evidence.localizedCaseInsensitiveContains("HDR10+")
            || codecTag == "dvh1" || codecTag == "dvhe"

        let depthFromPix = ["12", "10", "16"].first(where: { pixel.contains($0) }).flatMap(Int.init)
        let depth = int(video, "bits_per_raw_sample")
        let duration = number(string(video, "duration")) > 0
            ? number(string(video, "duration")) : number(string(format, "duration"))
        return MediaInfo(
            url: url, codec: codec, width: int(video, "width"), height: int(video, "height"),
            duration: duration, frameRate: number(string(video, "avg_frame_rate")),
            pixelFormat: pixel, bitDepth: depth > 0 ? depth : depthFromPix ?? 8,
            primaries: primaries, transfer: transfer, matrix: matrix,
            colorRange: range, audioCodecs: audio,
            sourceColor: color, dynamicHDR: dynamicHDR,
            dynamicHDRDescription: dynamicHDR ? evidence : nil,
            videoStreamIndex: video["index"] == nil ? offset : int(video, "index"),
            codecTag: codecTag,
            displayRotation: display == nil ? tagRotation : displayRotation,
            staticHDRMetadataPresent: hasStaticMetadata,
            hdrStaticMetadata: hdrMetadata,
            timeBase: string(video, "time_base"),
            isInterlaced: interlaced,
            detectedLogProfile: detected
        )
    }

    public static func inspect(tools: MediaTools, url: URL) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LumaError.invalidInput("Source file does not exist.")
        }
        let probe = try await CommandCapture.run(tools.ffprobe, [
            "-v", "error", "-show_streams", "-show_format", "-of", "json", url.path
        ], timeout: 35)
        guard var document = try JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
              let streams = document["streams"] as? [[String: Any]],
              let (offset, video) = mediaStream(streams) else {
            throw LumaError.invalidInput("No playable video stream was found.")
        }
        // Source MediaProbe.cs reads first decoded frames both for missing color
        // tags and for dynamic HDR side data. This is bounded, not exhaustive.
        if string(video, "codec_name") != "prores_raw" {
            let index = int(video, "index")
            let selection = index > 0 ? "\(index)" : "\(offset)"
            if let frames = try? await CommandCapture.run(tools.ffprobe, [
                "-v", "error", "-select_streams", selection,
                "-read_intervals", "%+#3", "-show_frames", "-of", "json", url.path
            ], timeout: 35, limit: 2 * 1024 * 1024),
            let parsed = try? JSONSerialization.jsonObject(with: frames.stdout) as? [String: Any],
            let framesArray = parsed["frames"] as? [[String: Any]] {
                document["frames"] = framesArray
            }
        }
        return try parse(JSONSerialization.data(withJSONObject: document), url: url)
    }
}
