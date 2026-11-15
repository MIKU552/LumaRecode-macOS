import Foundation
import XCTest
@testable import LumaCore

final class CommandCaptureTests: XCTestCase {
    func testCapturesSmallCommandOutput() async throws {
        let output = try await CommandCapture.run(
            URL(fileURLWithPath: "/bin/echo"), ["ok"], limit: 64
        )
        XCTAssertEqual(output.text, "ok\n")
        XCTAssertEqual(output.code, 0)
    }

    func testLargeProcessOutputIsBoundedAndRejected() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-capture-\(UUID().uuidString).txt")
        try Data(repeating: 65, count: 2 * 1024 * 1024).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            _ = try await CommandCapture.run(
                URL(fileURLWithPath: "/bin/cat"), [temporary.path],
                timeout: 15, limit: 4096
            )
            XCTFail("Large ffprobe-style output must fail rather than grow without bound.")
        } catch LumaError.processFailed(let message) {
            XCTAssertTrue(message.contains("safety limit"))
        }
    }
}
