import Foundation
import XCTest
@testable import LumaCore

final class FrameOutputVerifierTests: XCTestCase {
    func testRejectsZeroExpectedFramesBeforeRunningProbe() async {
        let tools = try! MediaTools(
            ffmpeg: URL(fileURLWithPath: "/bin/echo"),
            ffprobe: URL(fileURLWithPath: "/bin/echo")
        )
        do {
            try await FrameOutputVerifier.verify(
                tools: tools, encoded: URL(fileURLWithPath: "/tmp/a.mov"),
                expectedFrames: 0
            )
            XCTFail("Zero expected frames must be rejected.")
        } catch LumaError.invalidInput {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
