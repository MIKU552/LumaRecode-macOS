import Foundation

public struct EncoderCapabilities: Sendable {
    public let encoders: Set<String>
    public let filters: Set<String>
    public let version: String

    public func supports(_ name: String) -> Bool { encoders.contains(name) }

    /// FFmpeg 9+ and third-party builds may use different widths for the
    /// flag column. The "V->V" / "A->A" signature identifies real filters;
    /// never depend on fixed-width flag characters.
    static func parseFilterNames(_ listing: String) -> Set<String> {
        Set(listing.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, fields[2].contains("->") else { return nil }
            return String(fields[1])
        })
    }

    public static func discover(tools: MediaTools) async throws -> EncoderCapabilities {
        let version = try await CommandCapture.run(tools.ffmpeg, ["-version"], timeout: 15)
        let encoderData = try await CommandCapture.run(tools.ffmpeg, ["-hide_banner", "-encoders"], timeout: 15)
        let filterData = try await CommandCapture.run(tools.ffmpeg, ["-hide_banner", "-filters"], timeout: 15)
        let encoderNames: Set<String> = Set(encoderData.text.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count > 1, words[0].count == 6,
                  words[0].first == "V" || words[0].first == "A" else { return nil }
            return String(words[1])
        })
        let filterNames = parseFilterNames(filterData.text)
        return EncoderCapabilities(
            encoders: encoderNames, filters: filterNames,
            version: version.text.split(separator: "\n").first.map(String.init) ?? ""
        )
    }
}
