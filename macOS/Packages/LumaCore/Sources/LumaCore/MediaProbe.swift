import Foundation

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
        if pieces.count == 2, let numerator = Double(pieces[0]), let denominator = Double(pieces[1]),
           denominator != 0 { return numerator / denominator }
        return Double(value) ?? 0
    }
    public static func parse(_ data: Data, url: URL) throws -> MediaInfo {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = doc["streams"] as? [[String: Any]],
              let video = streams.first(where: { string($0, "codec_type") == "video" }) else {
            throw LumaError.invalidInput("No video stream was found.")
        }
        let audio = streams.filter { string($0, "codec_type") == "audio" }
            .map { string($0, "codec_name") }
        let format = (doc["format"] as? [String: Any]) ?? [:]
        let transfer = string(video, "color_transfer")
        let primaries = string(video, "color_primaries")
        let pixel = string(video, "pix_fmt")
        let codec = string(video, "codec_name")
        let profile = string(video, "profile").lowercased()
        let tags = (video["tags"] as? [String: Any]) ?? [:]
        let raw = codec == "prores_raw" || (codec == "prores" && profile.contains("raw"))
        let descriptionText = [string(tags, "com.apple.quicktime.camera.identifier"),
                               string(tags, "com.apple.quicktime.video-log-color-space"),
                               string(tags, "LogProfile")].joined(separator: " ").lowercased()
        let isLog = descriptionText.contains("log") && !descriptionText.contains("catalog")
        let color: SourceColor
        if raw { color = .raw }
        else if isLog { color = .log }
        else if transfer == "arib-std-b67" { color = .hlg }
        else if transfer == "smpte2084" { color = .pq }
        else if ["bt709", "iec61966-2-1", "smpte170m", "bt470bg"].contains(transfer) { color = .sdr }
        else { color = .unknown }

        let sideData = (video["side_data_list"] as? [[String: Any]]) ?? []
        let frameSideData = ((doc["frames"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["side_data_list"] as? [[String: Any]]) ?? [] }
        let evidence = (sideData + frameSideData)
            .map { string($0, "side_data_type") }.joined(separator: " ")
        let codecTag = string(video, "codec_tag_string").lowercased()
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
            primaries: primaries, transfer: transfer, matrix: string(video, "color_space"),
            colorRange: string(video, "color_range"), audioCodecs: audio,
            sourceColor: color, dynamicHDR: dynamicHDR,
            dynamicHDRDescription: dynamicHDR ? evidence : nil
        )
    }
    public static func inspect(tools: MediaTools, url: URL) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LumaError.invalidInput("Source file does not exist.")
        }
        let output = try await CommandCapture.run(tools.ffprobe, [
            "-v", "error", "-show_streams", "-show_format", "-of", "json", url.path
        ], timeout: 35)
        var info = try parse(output.stdout, url: url)
        // ffprobe often emits HDR10+ metadata on decoded frames rather than
        // stream headers. Inspect a bounded number of initial frames to avoid
        // accidentally dropping visible dynamic metadata in the basic path.
        // This is an early warning, NOT proof of absence later in the clip.
        if info.sourceColor.isHDR && !info.dynamicHDR {
            if let frames = try? await CommandCapture.run(tools.ffprobe, [
                "-v", "error", "-select_streams", "v:0",
                "-read_intervals", "%+#3", "-show_frames", "-of", "json", url.path
            ], timeout: 35, limit: 2 * 1024 * 1024),
               let document = try? JSONSerialization.jsonObject(with: frames.stdout) as? [String: Any],
               let items = document["frames"] as? [[String: Any]] {
                let evidence = items.flatMap {
                    ($0["side_data_list"] as? [[String: Any]]) ?? []
                }.map { string($0, "side_data_type") }.joined(separator: " ")
                if evidence.localizedCaseInsensitiveContains("DOVI")
                    || evidence.localizedCaseInsensitiveContains("Dolby Vision")
                    || evidence.localizedCaseInsensitiveContains("HDR10+") {
                    info.dynamicHDR = true
                    info.dynamicHDRDescription = evidence
                }
            }
        }
        return info
    }
}
