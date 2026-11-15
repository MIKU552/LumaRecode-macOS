import Foundation

/// Source: Windows Core/Transcoder.CheckRequirementsAsync.
/// Checks a *specific* resolved FFmpeg plan, not generic machine hardware
/// assumptions or a hard-coded list copied from Intel QSV.
public enum MediaRequirements {
    private static func argument(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag),
              args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    public static func validate(
        plan: EncodingPlan, capabilities: EncoderCapabilities
    ) throws {
        let args = plan.arguments
        guard let video = argument("-c:v", in: args), capabilities.encoders.contains(video) else {
            throw LumaError.toolsMissing(
                "The selected FFmpeg build does not provide the requested video encoder."
            )
        }
        guard let audio = argument("-c:a", in: args) else {
            throw LumaError.validationFailed("The encoding plan is missing its audio policy.")
        }
        if audio != "copy", !capabilities.encoders.contains(audio) {
            throw LumaError.toolsMissing("The selected FFmpeg build does not provide \(audio).")
        }

        guard let filterChain = argument("-vf", in: args) else {
            throw LumaError.validationFailed("The encoding plan has no video filter chain.")
        }
        let required = ["zscale", "setparams", "format", "lut3d", "libplacebo", "sidedata"]
            .filter { filterChain.contains("\($0)=") || filterChain.contains("\($0)@") }
        let missing = required.filter { !capabilities.filters.contains($0) }
        if !missing.isEmpty {
            throw LumaError.toolsMissing(
                "The selected FFmpeg build is missing video filters: \(missing.sorted().joined(separator: ", "))."
            )
        }
    }

    public static func check(tools: MediaTools, plan: EncodingPlan) async throws {
        let caps = try await EncoderCapabilities.discover(tools: tools)
        try validate(plan: plan, capabilities: caps)

        // Per Windows CheckRequirementsAsync, check the actual encoder pixel
        // format list when present. Some FFmpeg builds omit the declaration.
        guard plan.selection.purpose == .archive,
              let name = argument("-c:v", in: plan.arguments),
              let format = argument("-pix_fmt", in: plan.arguments) else { return }

        let help = try await CommandCapture.run(
            tools.ffmpeg, ["-hide_banner", "-h", "encoder=\(name)"], timeout: 20
        )
        guard let line = help.text.split(separator: "\n")
            .first(where: { $0.contains("Supported pixel formats:") }),
              let suffix = line.range(of: "Supported pixel formats:") else {
            return
        }
        let formats = line[suffix.upperBound...]
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard formats.contains(format) else {
            throw LumaError.unsupported(
                "\(name) in the selected FFmpeg build does not support \(format)."
            )
        }
    }
}
