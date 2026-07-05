import Foundation

/// Tracks per-process footprint history to derive a growth *rate* (bytes/sec)
/// over a trailing window. Rate-based detection catches a runaway leak long
/// before it reaches an absolute threshold — e.g. a process climbing 5 GB/min
/// is clearly misbehaving at 8 GB, well under a 50 GB pause limit.
final class GrowthTracker {
    private struct Point { let t: Date; let bytes: UInt64 }

    /// pid -> recent samples (oldest first).
    private var history: [pid_t: [Point]] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Record a new sample and return the current growth rate in bytes/sec,
    /// or nil if there isn't yet enough history spanning a useful interval.
    @discardableResult
    func record(pid: pid_t, bytes: UInt64, now: Date) -> Double? {
        var points = history[pid] ?? []
        points.append(Point(t: now, bytes: bytes))
        // Drop anything older than the window.
        let cutoff = now.addingTimeInterval(-window)
        points.removeAll { $0.t < cutoff }
        history[pid] = points

        guard let first = points.first, points.count >= 2 else { return nil }
        let dt = now.timeIntervalSince(first.t)
        guard dt >= 5 else { return nil } // need a few seconds of spread
        let delta = Double(bytes) - Double(first.bytes)
        return delta / dt
    }

    /// Forget processes that no longer exist to bound memory use.
    func prune(livePIDs: Set<pid_t>) {
        for pid in history.keys where !livePIDs.contains(pid) {
            history[pid] = nil
        }
    }
}
