import Foundation

public struct MediaTools {
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
        guard let probe = locate("ffprobe", configured: ffprobe) else {
            throw LumaError.toolsMissing("ffprobe was not found. Set its path in Settings.")
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
        for directory in envPaths + standardPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

public enum CommandCapture {
    public struct Output {
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
            let lock = NSLock()
            var out = Data()
            var err = Data()
            group.enter()
            DispatchQueue.global().async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); out = Data(data.prefix(limit + 1)); lock.unlock()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); err = Data(data.suffix(64 * 1024)); lock.unlock()
                group.leave()
            }
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
            group.wait()
            if out.count > limit { throw LumaError.processFailed("Command output exceeded safety limit.") }
            guard process.terminationStatus == 0 else {
                throw LumaError.processFailed(String(data: err, encoding: .utf8) ?? "Command failed.")
            }
            return Output(code: process.terminationStatus, stdout: out, stderr: err)
        }.value
    }
}
