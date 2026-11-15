import Foundation

/// Re-decodes a finished trimmed movie to verify exact display-frame count.
/// This intentionally adds work, as output is never published on an unverified
/// assumption about frame rate, timestamps, or encoder B-frame behavior.
public enum FrameOutputVerifier {
    public static func verify(
        tools: MediaTools, encoded: URL, expectedFrames: Int
    ) async throws {
        guard expectedFrames > 0 else {
            throw LumaError.invalidInput("Expected frame count must be positive.")
        }
        let report = try await CommandCapture.run(
            tools.ffprobe,
            ["-v", "error", "-count_frames", "-select_streams", "v:0",
             "-show_entries", "stream=nb_read_frames",
             "-of", "default=noprint_wrappers=1:nokey=1", encoded.path],
            timeout: 300, limit: 4096
        )
        let value = report.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Int(value) else {
            throw LumaError.validationFailed(
                "ffprobe could not confirm the trimmed video's decoded frame count."
            )
        }
        guard decoded == expectedFrames else {
            throw LumaError.validationFailed(
                "Frame trim produced \(decoded) frames instead of \(expectedFrames). "
                + "Output was not published."
            )
        }
    }
}
