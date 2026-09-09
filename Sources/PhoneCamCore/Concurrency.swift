import Foundation

/// A one-element mailbox. Slow consumers replace stale frames rather than growing a queue.
public final class LatestValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var replacements: UInt64 = 0
    public init() {}
    public func put(_ item: T) { lock.lock(); defer { lock.unlock() }; if value != nil { replacements += 1 }; value = item }
    public func take() -> T? { lock.lock(); defer { lock.unlock() }; let item = value; value = nil; return item }
    public func clear() { lock.lock(); value = nil; lock.unlock() }
    public var overwritten: UInt64 { lock.lock(); defer { lock.unlock() }; return replacements }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    /// For blocking I/O worker threads, never for the main queue.
    public func sleep(_ seconds: Double) {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !isCancelled && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: min(0.05, max(0, until - ProcessInfo.processInfo.systemUptime))) }
    }
}

public struct RetryBackoff {
    private var attempt = 0
    public init() {}
    public mutating func next() -> Double { defer { attempt = min(attempt + 1, 5) }; return min(8, 0.5 * pow(2, Double(attempt))) }
    public mutating func reset() { attempt = 0 }
}

/// Maps a potentially resetting device clock to a monotonic host-clock timeline.
public struct MonotonicClock {
    private var last: Int64 = -1
    public init() {}
    public mutating func next(hostNanoseconds: Int64) -> Int64 {
        let value = max(hostNanoseconds, last == Int64.max ? last : last + 1)
        last = value; return value
    }
}
