import Foundation
import Synchronization

public struct MediaTools: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) throws {
        for (name, url) in [("ffmpeg", ffmpeg), ("ffprobe", ffprobe)] {
            guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path) else {
                throw LumaError.toolsMissing("Invalid or non-executable \(name): \(url.path)")
            }
        }
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    public static func resolve(ffmpeg: String? = nil, ffprobe: String? = nil) throws -> MediaTools {
        guard let encoder = locate("ffmpeg", configured: ffmpeg) else {
            throw LumaError.toolsMissing("FFmpeg was not found. Install a suitable macOS build and set the path in Settings.")
        }
        // Prefer the ffprobe shipped alongside the selected FFmpeg so that
        // a custom binary and Homebrew's keg-only full version stay in sync.
        let sibling = encoder.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let probe: URL?
        if let ffprobe, !ffprobe.isEmpty {
            probe = locate("ffprobe", configured: ffprobe)
        } else if FileManager.default.isExecutableFile(atPath: sibling.path) {
            probe = sibling
        } else {
            probe = locate("ffprobe")
        }
        guard let probe else {
            throw LumaError.toolsMissing("ffprobe was not found. Select the matching binary in Settings.")
        }
        return try MediaTools(ffmpeg: encoder, ffprobe: probe)
    }

    public static func locate(_ name: String, configured: String? = nil) -> URL? {
        if let configured, !configured.isEmpty {
            let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Homebrew's ffmpeg-full is keg-only; prefer its complete zscale
        // pipeline while honoring explicit user-configured paths.
        let fullPaths = [
            "/opt/homebrew/opt/ffmpeg-full/bin",
            "/usr/local/opt/ffmpeg-full/bin"
        ]
        for directory in fullPaths + envPaths + standardPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

public enum CommandCapture {
    public struct Output: Sendable {
        public let code: Int32
        public let stdout: Data
        public let stderr: Data
        public var text: String { String(data: stdout, encoding: .utf8) ?? "" }
        public var errorText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    public static func run(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval = 30,
        limit: Int = 8 * 1024 * 1024
    ) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            try blockingRun(executable, arguments, timeout: timeout, limit: limit)
        }.value
    }

    // Keep synchronous process and DispatchGroup waits out of the async function.
    // The detached task provides the asynchronous boundary for callers.
    private static func blockingRun(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval,
        limit: Int
    ) throws -> Output {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            // Read both pipes concurrently to prevent blocking on a full pipe.
            let group = DispatchGroup()
            let out = Mutex(Data())
            let err = Mutex(Data())
            let overflow = Mutex(false)
            group.enter()
            DispatchQueue.global().async {
                let file = stdout.fileHandleForReading
                // ffprobe's frame index may be huge: never read the entire
                // subprocess stream before applying the caller's byte cap.
                while true {
                    let chunk = file.readData(ofLength: 32 * 1024)
                    if chunk.isEmpty { break }
                    let tooLarge = out.withLock { buffer -> Bool in
                        let remaining = max(0, limit - buffer.count)
                        buffer.append(chunk.prefix(remaining))
                        return chunk.count > remaining
                    }
                    if tooLarge {
                        overflow.withLock { $0 = true }
                        if process.isRunning { process.terminate() }
                        break
                    }
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let file = stderr.fileHandleForReading
                while true {
                    let chunk = file.readData(ofLength: 32 * 1024)
                    if chunk.isEmpty { break }
                    err.withLock { buffer in
                        buffer.append(chunk)
                        if buffer.count > 64 * 1024 {
                            buffer.removeFirst(buffer.count - 64 * 1024)
                        }
                    }
                }
                group.leave()
            }
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
            group.wait()
            let stdoutData = out.withLock { $0 }
            let stderrData = err.withLock { $0 }
            if overflow.withLock({ $0 }) {
                throw LumaError.processFailed("Command output exceeded safety limit.")
            }
            guard process.terminationStatus == 0 else {
                throw LumaError.processFailed(String(data: stderrData, encoding: .utf8) ?? "Command failed.")
            }
            return Output(code: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
    }
}
