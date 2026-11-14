import Foundation

public struct EncoderCapabilities {
    public let encoders: Set<String>
    public let filters: Set<String>
    public let version: String

    public func supports(_ name: String) -> Bool { encoders.contains(name) }

    public static func discover(tools: MediaTools) async throws -> EncoderCapabilities {
        let version = try await CommandCapture.run(tools.ffmpeg, ["-version"], timeout: 15)
        let encoderData = try await CommandCapture.run(tools.ffmpeg, ["-hide_banner", "-encoders"], timeout: 15)
        let filterData = try await CommandCapture.run(tools.ffmpeg, ["-hide_banner", "-filters"], timeout: 15)
        let encoderNames: Set<String> = Set(encoderData.text.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count > 1, words[0].count == 6, words[0].first == "V" else { return nil }
            return String(words[1])
        })
        let filterNames: Set<String> = Set(filterData.text.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count > 1, words[0].count == 3 else { return nil }
            return String(words[1])
        })
        return EncoderCapabilities(
            encoders: encoderNames, filters: filterNames,
            version: version.text.split(separator: "\n").first.map(String.init) ?? ""
        )
    }
}
