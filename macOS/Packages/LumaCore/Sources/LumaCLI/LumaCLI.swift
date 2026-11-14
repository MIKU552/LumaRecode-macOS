import Foundation
import LumaCore

@main
struct LumaCLI {
    private static func value(_ key: String, args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func emit(_ name: String, _ data: [String: Any] = [:]) {
        let event: [String: Any] = ["schema_version": 1, "event": name, "data": data]
        if let json = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
           let line = String(data: json, encoding: .utf8) {
            print(line)
        }
    }

    private static func help() {
        print("""
        LumaRecode for macOS — native Swift command-line interface

        Usage:
          lumarecode doctor [--ffmpeg PATH] [--ffprobe PATH]
          lumarecode probe INPUT [--json]
          lumarecode plan INPUT [--codec hevc|avc|av1] [--purpose archive|share] [--output PATH]
          lumarecode convert INPUT [--codec ...] [--purpose ...] [--output PATH] [--overwrite] [--json]

        Unported features (HDR10+ and Dolby Vision preservation, Log/RAW development,
        frame-accurate trimming, Live Photos) are blocked rather than approximated.
        """)
    }

    static func main() async {
        do {
            let words = Array(CommandLine.arguments.dropFirst())
            guard let command = words.first, !["help", "--help", "-h"].contains(command) else {
                help()
                return
            }
            let tools = try MediaTools.resolve(
                ffmpeg: value("--ffmpeg", args: words), ffprobe: value("--ffprobe", args: words)
            )
            if command == "doctor" {
                let caps = try await EncoderCapabilities.discover(tools: tools)
                emit("doctor", [
                    "version": caps.version,
                    "encoders": caps.encoders.sorted(),
                    "filters": caps.filters.sorted()
                ])
                return
            }
            guard ["probe", "plan", "convert"].contains(command), words.count >= 2 else {
                throw LumaError.unsupported("Unknown or not-yet-ported CLI command: \(command)")
            }
            let input = URL(fileURLWithPath: words[1]).standardizedFileURL
            let media = try await MediaProbe.inspect(tools: tools, url: input)
            if command == "probe" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(media)
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let codecName = value("--codec", args: words) ?? "hevc"
            let purposeName = value("--purpose", args: words) ?? "archive"
            guard let codec = VideoCodec(rawValue: codecName),
                  let purpose = EncodePurpose(rawValue: purposeName) else {
                throw LumaError.invalidInput("Invalid codec or purpose.")
            }
            let selection = EncodeSelection(purpose: purpose, codec: codec)
            let destination: URL
            if let path = value("--output", args: words) {
                destination = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                destination = EncodingPlanner.destination(
                    for: media, selection: selection, directory: input.deletingLastPathComponent()
                )
            }
            let plan = try EncodingPlanner.plan(
                tools: tools, media: media, selection: selection, destination: destination
            )
            if command == "plan" {
                emit("plan", ["argv": [plan.executable.path] + plan.arguments,
                              "output": destination.path,
                              "codec": selection.codec.rawValue,
                              "purpose": selection.purpose.rawValue])
                return
            }
            let session = ConversionSession()
            emit("start", ["input": input.path, "output": destination.path])
            let result = try await session.execute(
                plan: plan, tools: tools, source: media,
                overwrite: words.contains("--overwrite"),
                onProgress: { p in
                    emit("progress", ["percent": p.fraction * 100,
                                       "position_seconds": p.seconds,
                                       "duration_seconds": p.duration,
                                       "fps": p.fps as Any? ?? NSNull()])
                }
            )
            emit("done", ["output": result.path])
        } catch {
            emit("error", ["message": error.localizedDescription])
            Foundation.exit(1)
        }
    }
}
