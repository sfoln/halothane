import Foundation

/// A point-in-time snapshot of one process's memory state.
struct ProcSample: Identifiable, Hashable, Codable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String?
    /// Activity Monitor's "Memory" column: phys_footprint in bytes.
    let footprint: UInt64
    /// Bytes/second over the trailing growth window (nil until enough history).
    var growthRate: Double?
    let timestamp: Date

    var id: pid_t { pid }

    var footprintGB: Double { Double(footprint) / 1_073_741_824.0 }
    var growthMBPerMin: Double? { growthRate.map { $0 / 1_048_576.0 * 60.0 } }
}

/// What the policy engine decided to do about a process this tick.
enum Severity: Int, Comparable, Codable {
    case normal = 0
    case warn = 1
    case pause = 2

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum DecisionReason: String, Equatable, Codable {
    case none
    case footprintWarn
    case footprintPause
    case growthWarn
    case growthPause
    case systemPressure
    case manual

    var label: String {
        switch self {
        case .none: return ""
        case .footprintWarn: return "high memory"
        case .footprintPause: return "memory over pause limit"
        case .growthWarn: return "growing fast"
        case .growthPause: return "runaway growth"
        case .systemPressure: return "system memory critical"
        case .manual: return "paused manually"
        }
    }
}

struct Decision {
    let severity: Severity
    let reason: DecisionReason
}

/// A process currently held in SIGSTOP by Halothane, with context for the UI.
struct PausedProcess: Identifiable, Hashable, Codable {
    let pid: pid_t
    let name: String
    let footprintAtPause: UInt64
    let reason: DecisionReason
    let pausedAt: Date
    /// Child pids that were also stopped as part of the tree.
    let pausedTree: [pid_t]

    var id: pid_t { pid }
    var footprintGB: Double { Double(footprintAtPause) / 1_073_741_824.0 }
}

/// An entry in the activity log shown in the menu.
struct LogEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let time: Date
    let message: String
}

/// An autocomplete candidate for the rule/whitelist process picker. We display
/// (and match rules on) `name`, but also search `path` so processes whose
/// proc_name is unhelpful (e.g. a bare version like "2.1.186") are still
/// findable by typing something from their path.
struct ProcCandidate: Hashable, Identifiable {
    let name: String
    let path: String?
    var id: String { name }
}

/// One row in the floating HUD. The attention set is maintained with a short
/// linger so transient (growth) warns don't flash away before they're read.
struct HUDItem: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let footprint: UInt64
    let paused: Bool
    var id: pid_t { pid }
    var footprintGB: Double { Double(footprint) / 1_073_741_824.0 }
}

/// A discrete event the engine emits for the UI to surface as a notification.
struct SupervisorEvent: Codable, Hashable {
    enum Kind: String, Codable { case warn, paused, resumed, killed, info }
    let kind: Kind
    let title: String
    let body: String
    let pid: pid_t
}

/// Everything the UI needs to render, produced by the engine each tick and
/// shipped verbatim over XPC from the daemon (or delivered in-process).
struct Snapshot: Codable {
    var top: [ProcSample]         // biggest few, for the menu
    var all: [ProcSample]         // fuller list (above floor), for the detail view
    var paused: [PausedProcess]
    var pressure: String          // MemoryPressureMonitor.Level rawValue
    var status: Severity
    var log: [LogEntry]
    var backendIsRoot: Bool
    /// When monitoring is paused ("disarmed"), the time it auto-resumes — or
    /// `Date.distantFuture` for "until I resume". `nil` means armed/active.
    /// Optional so it decodes to nil from an older daemon that doesn't send it.
    var disarmedUntil: Date?
}
