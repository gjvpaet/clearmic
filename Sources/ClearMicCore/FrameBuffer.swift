import Foundation

/// Thread-safe first-in-first-out queue of audio samples.
public final class FrameBuffer {
    private var samples: [Float] = []
    private let lock = NSLock()

    public init() {}

    public var count: Int { lock.withLock { samples.count } }

    public func push(_ new: [Float]) {
        lock.withLock { samples.append(contentsOf: new) }
    }

    /// Returns exactly `n` samples, or nil if fewer are queued.
    public func pop(_ n: Int) -> [Float]? {
        lock.withLock {
            guard samples.count >= n else { return nil }
            let out = Array(samples.prefix(n))
            samples.removeFirst(n)
            return out
        }
    }

    /// Drops the oldest samples until at most `max` remain. Returns how many were dropped.
    public func dropOldest(downTo max: Int) -> Int {
        lock.withLock {
            let extra = samples.count - max
            guard extra > 0 else { return 0 }
            samples.removeFirst(extra)
            return extra
        }
    }
}
