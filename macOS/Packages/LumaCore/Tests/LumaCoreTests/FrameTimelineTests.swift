import XCTest
@testable import LumaCore

final class FrameTimelineTests: XCTestCase {
    func testVariableFrameRateBoundaryAndBinarySearch() throws {
        let timeline = try FrameTimeline(
            frames: [
                FramePoint(pts: 0, duration: 100, keyFrame: true),
                FramePoint(pts: 100, duration: 200),
                FramePoint(pts: 300, duration: 100),
                FramePoint(pts: 400, duration: 100)
            ],
            numerator: 1, denominator: 1000, packetIndexed: true
        )
        XCTAssertEqual(timeline.count, 4)
        XCTAssertEqual(timeline.duration, 0.5, accuracy: 0.000001)
        XCTAssertEqual(try timeline.atOrAfter(0.1), 1)
        XCTAssertEqual(try timeline.atOrAfter(0.2), 2)
        XCTAssertEqual(try timeline.atOrAfter(0.5), 4)
        let window = try timeline.resolve(FrameRange(start: 1, end: 3))
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.startSeconds, 0.1, accuracy: 0.000001)
        XCTAssertEqual(window.endSeconds, 0.4, accuracy: 0.000001)
    }

    func testNearestSafeNonnegativeKeyframeSeek() throws {
        let timeline = try FrameTimeline(
            frames: [
                FramePoint(pts: -100, duration: 100, keyFrame: true),
                FramePoint(pts: 0, duration: 100),
                FramePoint(pts: 100, duration: 100, keyFrame: true),
                FramePoint(pts: 200, duration: 100)
            ],
            numerator: 1, denominator: 1000, packetIndexed: true
        )
        let w = try timeline.resolve(FrameRange(start: 3))
        XCTAssertEqual(w.seekFrame, 2)
        XCTAssertEqual(w.seekSeconds, 0.1, accuracy: 0.000001)
        XCTAssertEqual(w.count, 1)
    }

    func testDecodedTimelineNeverUsesPacketSeek() throws {
        let timeline = try FrameTimeline(
            frames: [
                FramePoint(pts: 20, keyFrame: true),
                FramePoint(pts: 40),
                FramePoint(pts: 60, keyFrame: true)
            ],
            numerator: 1, denominator: 1000, packetIndexed: false
        )
        XCTAssertEqual(try timeline.resolve(FrameRange(start: 2)).seekFrame, 0)
    }

    func testCompactPacketsIgnoreDiscardedPreroll() throws {
        let content = """
        packet|pts=-1024|duration=1024|flags=KD
        packet|pts=0|duration=1024|flags=K_
        packet|pts=1024|duration=1024|flags=__
        """
        let result = try XCTUnwrap(FrameTimelineLoader.parseCompact(content, packets: true))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].pts, 0)
        XCTAssertTrue(result[0].keyFrame)
    }

    func testMalformedPacketTimestampTriggersDecodedFallback() {
        let content = """
        packet|pts=0|duration=1024|flags=K_
        packet|pts=N/A|duration=1024|flags=__
        """
        XCTAssertNil(FrameTimelineLoader.parseCompact(content, packets: true))
    }

    func testDecodedCompactParsing() throws {
        let content = """
        frame|best_effort_timestamp=120|duration=40|key_frame=1
        frame|best_effort_timestamp=160|duration=40|key_frame=0
        """
        let frames = try XCTUnwrap(FrameTimelineLoader.parseCompact(content, packets: false))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1].pts, 160)
        XCTAssertFalse(frames[1].keyFrame)
    }

    func testNoFpsApproximationForInvalidIndex() {
        XCTAssertThrowsError(try FrameTimeline(frames: [], numerator: 1,
                                               denominator: 1000, packetIndexed: true))
        XCTAssertThrowsError(try FrameTimeline(frames: [
            FramePoint(pts: 100), FramePoint(pts: 0)
        ], numerator: 1, denominator: 1000, packetIndexed: true))
    }

    func testInvalidRangeOrTimeRejected() throws {
        let timeline = try FrameTimeline(
            frames: [FramePoint(pts: 0), FramePoint(pts: 10)],
            numerator: 1, denominator: 1000, packetIndexed: true
        )
        XCTAssertThrowsError(try timeline.resolve(FrameRange(start: 1, end: 1)))
        XCTAssertThrowsError(try timeline.atOrAfter(.nan))
    }
}
