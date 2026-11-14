import XCTest
@testable import LumaCore

final class ProgressTests: XCTestCase {
    func testMicrosecondsProgress() {
        var parser = ProgressParser()
        XCTAssertNil(parser.accept("fps=48.5", duration: 10))
        let status = parser.accept("out_time_us=2500000", duration: 10)
        XCTAssertEqual(status?.seconds, 2.5)
        XCTAssertEqual(status?.fraction, 0.25)
        XCTAssertEqual(status?.fps, 48.5)
    }
    func testClampsProgress() {
        let status = TranscodeProgress(seconds: 100, duration: 10, fps: nil)
        XCTAssertEqual(status.fraction, 1)
    }
}
