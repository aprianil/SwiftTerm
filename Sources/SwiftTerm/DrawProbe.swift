import Foundation

/// Counts, for one second at a time, how a view keeps up with an application
/// that draws in synchronized frames (DECSET 2026): how many frames closed on
/// a view in a window, how many display updates went out with the frame
/// closed (`presented`), how many draws there were, how many of those drew
/// while a frame was still open (a torn picture), and how long a closed frame
/// waited for the display update that showed it. Off unless `armed`; on, it is a
/// few integer adds per frame and per draw, on the main thread only.
public enum DrawProbe {
    public static var armed = false

    public struct Second {
        public let framesClosed: Int
        public let presented: Int
        public let draws: Int
        public let tornDraws: Int
        public let waitAverageMs: Double
        public let waitMaxMs: Double
    }

    private static var framesClosed = 0
    private static var presentations = 0
    private static var draws = 0
    private static var tornDraws = 0
    private static var waitSumNs: UInt64 = 0
    private static var waitMaxNs: UInt64 = 0
    private static var waits = 0
    private static var closedAt: UInt64 = 0

    static func frameClosed() {
        guard armed else { return }
        framesClosed += 1
        if closedAt == 0 { closedAt = DispatchTime.now().uptimeNanoseconds }
    }

    static func drew(torn: Bool) {
        guard armed else { return }
        draws += 1
        if torn { tornDraws += 1 }
    }

    static func presented() {
        guard armed else { return }
        presentations += 1
        guard closedAt != 0 else { return }
        let wait = DispatchTime.now().uptimeNanoseconds &- closedAt
        closedAt = 0
        waitSumNs &+= wait
        waitMaxNs = max(waitMaxNs, wait)
        waits += 1
    }

    /// The counts since the last call, and a fresh second.
    public static func take() -> Second {
        let second = Second(
            framesClosed: framesClosed, presented: presentations, draws: draws, tornDraws: tornDraws,
            waitAverageMs: waits == 0 ? 0 : Double(waitSumNs) / Double(waits) / 1e6,
            waitMaxMs: Double(waitMaxNs) / 1e6)
        framesClosed = 0; presentations = 0; draws = 0; tornDraws = 0
        waitSumNs = 0; waitMaxNs = 0; waits = 0
        return second
    }
}
