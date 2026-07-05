import Foundation

/// Wraps the kernel's memory-pressure notification — the same signal the OS
/// uses internally before it starts killing processes. When the system goes
/// critical we proactively pause the single largest non-exempt offender even
/// if it's under its own threshold, to relieve pressure before the OS panics.
final class MemoryPressureMonitor {
    enum Level: String { case normal, warning, critical }

    private var source: DispatchSourceMemoryPressure?
    private(set) var level: Level = .normal
    var onChange: ((Level) -> Void)?

    func start(queue: DispatchQueue) {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            let newLevel: Level
            if data.contains(.critical) { newLevel = .critical }
            else if data.contains(.warning) { newLevel = .warning }
            else { newLevel = .normal }
            if newLevel != self.level {
                self.level = newLevel
                self.onChange?(newLevel)
            }
        }
        src.resume()
        self.source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
