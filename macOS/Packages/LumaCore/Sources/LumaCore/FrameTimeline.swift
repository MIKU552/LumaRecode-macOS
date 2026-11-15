import Foundation

/// Zero-based, end-exclusive display-frame selection. Based on the Windows
/// Core/FrameTimeline.cs mathematical contract; no FPS rounding is used.
public struct FrameRange: Equatable, Sendable {
    public let start: Int
    public let end: Int?
    public init(start: Int = 0, end: Int? = nil) {
        self.start = start
        self.end = end
    }
}

public struct FramePoint: Equatable, Sendable {
    public let pts: Int64
    public let duration: Int64
    public let keyFrame: Bool
    public init(pts: Int64, duration: Int64 = 0, keyFrame: Bool = false) {
        self.pts = pts
        self.duration = duration
        self.keyFrame = keyFrame
    }
}

public struct FrameWindow: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let seekFrame: Int
    public let seekSeconds: Double
    public let startSeconds: Double
    public let endSeconds: Double
    public var count: Int { end - start }
    public var duration: Double { endSeconds - startSeconds }
}

public struct FrameTimeline: Sendable {
    public let frames: [FramePoint]
    public let numerator: Int64
    public let denominator: Int64
    public let packetIndexed: Bool
    public var count: Int { frames.count }

    public init(
        frames: [FramePoint], numerator: Int64,
        denominator: Int64, packetIndexed: Bool
    ) throws {
        guard !frames.isEmpty, numerator > 0, denominator > 0 else {
            throw LumaError.invalidInput("Cannot establish frame timeline: invalid time base or no frames.")
        }
        guard zip(frames, frames.dropFirst()).allSatisfy({ $0.pts <= $1.pts }) else {
            throw LumaError.invalidInput("Non-monotonic displayed timestamps; refusing FPS approximation.")
        }
        self.frames = frames
        self.numerator = numerator
        self.denominator = denominator
        self.packetIndexed = packetIndexed
    }

    public func seconds(_ index: Int) -> Double {
        Double(frames[index].pts) * Double(numerator) / Double(denominator)
    }
    public func position(_ index: Int) -> Double {
        seconds(index) - seconds(0)
    }
    public func boundarySeconds(_ index: Int) -> Double {
        guard index == count else { return seconds(index) }
        let last = frames[count - 1]
        let duration = last.duration > 0 ? last.duration :
            count > 1 ? max(1, last.pts - frames[count - 2].pts) : 1
        return Double(last.pts + duration) * Double(numerator) / Double(denominator)
    }
    public var duration: Double { boundarySeconds(count) - seconds(0) }

    /// Binary search for first frame at or after the relative display time.
    public func atOrAfter(_ positionSeconds: Double) throws -> Int {
        guard positionSeconds.isFinite, positionSeconds >= 0 else {
            throw LumaError.invalidInput("Frame position must be a finite non-negative time.")
        }
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if position(middle) + 1e-9 < positionSeconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    public func resolve(_ range: FrameRange) throws -> FrameWindow {
        let end = range.end ?? count
        guard range.start >= 0, range.start < end, end <= count else {
            throw LumaError.invalidInput(
                "Invalid frame selection; start must precede end and end must be ≤ \(count)."
            )
        }
        var seek = 0
        if packetIndexed {
            for index in stride(from: range.start, through: 0, by: -1) {
                if frames[index].keyFrame && seconds(index) >= 0 {
                    seek = index
                    break
                }
            }
        }
        return FrameWindow(
            start: range.start, end: end, seekFrame: seek,
            seekSeconds: seek == 0 ? 0 : seconds(seek),
            startSeconds: seconds(range.start), endSeconds: boundarySeconds(end)
        )
    }
}
