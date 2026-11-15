import Foundation
import LumaCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct LumaCLI {
    private static func value(_ key: String, args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func optionalInt(_ key: String, args: [String]) throws -> Int? {
        guard let raw = value(key, args: args) else { return nil }
        guard let number = Int(raw), number >= 0 else {
            throw LumaError.invalidInput("\(key) must be a non-negative integer.")
        }
        return number
    }

    private static func optionalTime(_ key: String, args: [String]) throws -> Double? {
        guard let raw = value(key, args: args) else { return nil }
        guard let number = Double(raw), number.isFinite && number >= 0 else {
            throw LumaError.invalidInput("\(key) must be a finite non-negative time.")
        }
        return number
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
          lumarecode frames INPUT    # exact original PTS frame count / time base
          lumarecode plan INPUT [--codec hevc|avc|av1] [--purpose archive|share] [--output PATH]
          lumarecode convert INPUT [--codec ...] [--purpose ...] [--output PATH] [--overwrite] [--json]
          lumarecode convert INPUT --start-frame 10 --end-frame 40 [--codec hevc]
          lumarecode convert INPUT --start-time 0.5 --end-time 2.0 [--codec hevc]

        Frame trim uses zero-based display frames and an end-exclusive boundary.
        --start-frame / --end-frame and --start-time / --end-time are mutually exclusive.
        Audio tracks are re-encoded (AAC by default), never stream-copied during trimming.

        Format policy (from Windows OutputPolicy):
          --sampling auto|source|420|422|444|gray
          --depth auto|8|10|12
          --range auto|source|limited|full
          --audio auto|copy|aac|opus
          --fast  (software archive AV1 only)

        Unported features (HDR10+ and Dolby Vision preservation, Log/RAW development,
        Live Photos) are blocked rather than approximated.
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
            guard ["probe", "frames", "plan", "convert"].contains(command), words.count >= 2 else {
                throw LumaError.unsupported("Unknown or not-yet-ported CLI command: \(command)")
            }
            let input = URL(fileURLWithPath: words[1]).standardizedFileURL
            let media = try await MediaProbe.inspect(tools: tools, url: input)
            if command == "frames" {
                let timeline = try await FrameTimelineLoader.load(tools: tools, media: media)
                let payload: [String: Any] = [
                    "schema_version": 1, "input": input.path,
                    "frames": timeline.count,
                    "duration": timeline.duration,
                    "time_base": "\(timeline.numerator)/\(timeline.denominator)",
                    "first_pts": timeline.frames[0].pts,
                    "last_pts": timeline.frames[timeline.count - 1].pts,
                    "packet_indexed": timeline.packetIndexed
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
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
            guard let sampling = SamplingChoice(rawValue: value("--sampling", args: words) ?? "auto"),
                  let depth = BitDepthChoice(rawValue: value("--depth", args: words) ?? "auto"),
                  let range = SampleRangeChoice(rawValue: value("--range", args: words) ?? "auto"),
                  let audio = AudioChoice(rawValue: value("--audio", args: words) ?? "auto") else {
                throw LumaError.invalidInput("Invalid sampling, depth, range, or audio option.")
            }
            let selection = EncodeSelection(
                purpose: purpose, codec: codec, sampling: sampling,
                bitDepth: depth, colorRange: range, audio: audio,
                variant: words.contains("--fast") ? .fast : .standard
            )
            let destination: URL
            if let path = value("--output", args: words) {
                destination = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                destination = EncodingPlanner.destination(
                    for: media, selection: selection, directory: input.deletingLastPathComponent()
                )
            }
            let startFrame = try optionalInt("--start-frame", args: words)
            let endFrame = try optionalInt("--end-frame", args: words)
            let startTime = try optionalTime("--start-time", args: words)
            let endTime = try optionalTime("--end-time", args: words)
            let wantsTrim = startFrame != nil || endFrame != nil
                || startTime != nil || endTime != nil
            let trimmed: TrimmedEncodingPlan?
            let plan: EncodingPlan
            if wantsTrim {
                let timeline = try await FrameTimelineLoader.load(tools: tools, media: media)
                let range = try FrameTrimPlanner.resolve(
                    in: timeline, startFrame: startFrame, endFrame: endFrame,
                    startTime: startTime, endTime: endTime
                )
                let built = try FrameTrimPlanner.plan(
                    tools: tools, media: media, selection: selection,
                    destination: destination, timeline: timeline, range: range
                )
                trimmed = built
                plan = built.encoding
            } else {
                trimmed = nil
                plan = try EncodingPlanner.plan(
                    tools: tools, media: media, selection: selection,
                    destination: destination
                )
            }
            if command == "plan" {
                emit("plan", ["argv": [plan.executable.path] + plan.arguments,
                              "output": destination.path,
                              "codec": selection.codec.rawValue,
                              "purpose": selection.purpose.rawValue,
                              "sampling": selection.sampling.rawValue,
                              "bit_depth": selection.bitDepth.rawValue,
                              "color_range": selection.colorRange.rawValue,
                              "audio": selection.audio.rawValue,
                              "variant": selection.variant.rawValue,
                              "effective_audio": plan.selection.audio.rawValue,
                              "trim_start_frame": trimmed?.window.start as Any? ?? NSNull(),
                              "trim_end_frame": trimmed?.window.end as Any? ?? NSNull(),
                              "expected_frames": trimmed?.window.count as Any? ?? NSNull()
                ])
                return
            }
            let session = ConversionSession()
            emit("start", [
                "input": input.path, "output": destination.path,
                "expected_frames": trimmed?.window.count as Any? ?? NSNull()
            ])
            let result = try await session.execute(
                plan: plan, tools: tools, source: media,
                overwrite: words.contains("--overwrite"),
                expectedFrames: trimmed?.window.count,
                progressDuration: trimmed?.window.duration,
                onProgress: { p in
                    emit("progress", ["percent": p.fraction * 100,
                                      "position_seconds": p.seconds,
                                      "duration_seconds": p.duration,
                                      "fps": p.fps as Any? ?? NSNull()])
                }
            )
            emit("done", [
                "output": result.path,
                "frames": trimmed?.window.count as Any? ?? NSNull()
            ])
        } catch {
            emit("error", ["message": error.localizedDescription])
            exit(1)
        }
    }
}
