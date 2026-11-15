import Foundation
import Synchronization

/// A single-use, cancellable conversion. Never writes directly to the final destination.
public final class ConversionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func setProcess(_ running: Process?) {
        lock.lock()
        process = running
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel, let running, running.isRunning { running.terminate() }
    }

    public func execute(
        plan: EncodingPlan, tools: MediaTools, source: MediaInfo,
        overwrite: Bool = false,
        onProgress: @escaping @Sendable (TranscodeProgress) -> Void = { _ in }
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.url.path) else {
            throw LumaError.invalidInput("Source file is no longer available.")
        }
        guard !fm.fileExists(atPath: plan.destination.path) || overwrite else {
            throw LumaError.invalidInput("Destination already exists. Choose another name, or explicitly allow replacement.")
        }
        guard fm.fileExists(atPath: plan.destination.deletingLastPathComponent().path) else {
            throw LumaError.invalidInput("Output directory does not exist.")
        }
        defer { try? fm.removeItem(at: plan.temporary) }
        if isCancelled() { throw LumaError.cancelled }
        try await run(plan: plan, duration: source.duration, onProgress: onProgress)
        if isCancelled() { throw LumaError.cancelled }
        guard fm.fileExists(atPath: plan.temporary.path) else {
            throw LumaError.validationFailed("Encoder produced no output file.")
        }
        let attributes = try fm.attributesOfItem(atPath: plan.temporary.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw LumaError.validationFailed("Encoder output is empty.")
        }
        let output = try await MediaProbe.inspect(tools: tools, url: plan.temporary)
        guard output.codec == plan.expectedCodec.ffprobeName else {
            throw LumaError.validationFailed("Output codec differs from the requested codec.")
        }
        guard output.width > 0, output.height > 0 else {
            throw LumaError.validationFailed("Output has no valid picture dimensions.")
        }
        if source.sourceColor.isHDR {
            guard output.sourceColor == source.sourceColor, output.bitDepth >= 10 else {
                throw LumaError.validationFailed("Output lost its HDR transfer or 10-bit precision.")
            }
        }
        guard output.audioCodecs.count == source.audioCodecs.count else {
            throw LumaError.validationFailed("Output audio-track count differs from the source.")
        }
        if isCancelled() { throw LumaError.cancelled }

        // Publish only after complete output verification, preserving the original on error.
        if fm.fileExists(atPath: plan.destination.path) {
            guard overwrite else { throw LumaError.invalidInput("Destination exists.") }
            // macOS NSFileManager replacement happens in one destination directory.
            _ = try fm.replaceItemAt(plan.destination, withItemAt: plan.temporary)
        } else {
            try fm.moveItem(at: plan.temporary, to: plan.destination)
        }
        return plan.destination
    }

    private func run(
        plan: EncodingPlan, duration: Double,
        onProgress: @escaping @Sendable (TranscodeProgress) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = plan.executable
                task.arguments = plan.arguments
                let stdout = Pipe()
                let stderr = Pipe()
                task.standardOutput = stdout
                task.standardError = stderr
                var lastSeconds = 0.0
                var lastFPS: Double? = nil
                let group = DispatchGroup()
                do {
                    if self.isCancelled() { throw LumaError.cancelled }
                    try task.run()
                    self.setProcess(task)
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let file = stdout.fileHandleForReading
                        var pending = Data()
                        while true {
                            let chunk = file.availableData
                            if chunk.isEmpty { break }
                            pending.append(chunk)
                            while let range = pending.range(of: Data([10])) {
                                let line = String(decoding: pending.subdata(in: 0..<range.lowerBound), as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                pending.removeSubrange(0..<range.upperBound)
                                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                                    let value = String(line.split(separator: "=", maxSplits: 1).last ?? "")
                                    if let micros = Double(value) {
                                        lastSeconds = max(0, micros / 1_000_000)
                                        onProgress(TranscodeProgress(seconds: lastSeconds,
                                                                   duration: duration, fps: lastFPS))
                                    }
                                } else if line.hasPrefix("fps=") {
                                    lastFPS = Double(line.dropFirst(4))
                                }
                            }
                            if pending.count > 16 * 1024 { pending.removeAll(keepingCapacity: false) }
                        }
                        group.leave()
                    }
                    group.enter()
                    let stderrTail = Mutex(Data())
                    DispatchQueue.global(qos: .utility).async {
                        let file = stderr.fileHandleForReading
                        while true {
                            let chunk = file.availableData
                            if chunk.isEmpty { break }
                            stderrTail.withLock { buffer in
                                buffer.append(chunk)
                                if buffer.count > 64 * 1024 {
                                    buffer.removeFirst(buffer.count - 64 * 1024)
                                }
                            }
                        }
                        group.leave()
                    }
                    task.waitUntilExit()
                    group.wait()
                    self.setProcess(nil)
                    if self.isCancelled() { throw LumaError.cancelled }
                    guard task.terminationStatus == 0 else {
                        throw LumaError.processFailed(
                            stderrTail.withLock { String(data: $0, encoding: .utf8) }
                            ?? "FFmpeg failed with exit code \(task.terminationStatus)."
                        )
                    }
                    continuation.resume()
                } catch {
                    self.setProcess(nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
