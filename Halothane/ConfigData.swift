import Foundation

/// Physical RAM, used to turn percent thresholds into byte values.
enum Hardware {
    static let totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    static var totalGB: Double { Double(totalBytes) / 1_073_741_824.0 }
}

/// When the always-on-top floating overlay appears.
enum HUDMode: String, Codable, CaseIterable, Identifiable {
    case off
    case warnAndPause
    case pauseOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .warnAndPause: return "Warnings & pauses"
        case .pauseOnly: return "Pauses only"
        }
    }
}

/// Immutable value snapshot of all settings. The engine (`SupervisorCore`)
/// operates purely on this, so it's identical in-process and in the daemon,
/// and it's what crosses XPC when the UI pushes config changes to the daemon.
///
/// Thresholds can be expressed as a percent of physical RAM (default — it's
/// machine-relative) or as absolute GB. The engine always resolves them to
/// bytes via `effective*Bytes`.
struct ConfigData: Codable, Equatable {
    var percentMode: Bool
    var warnPercent: Double
    var pausePercent: Double
    var warnGB: Double
    var pauseGB: Double
    var autoPauseEnabled: Bool
    var growthDetectionEnabled: Bool
    var growthWarnMBPerMin: Double
    var growthAutoPauseEnabled: Bool
    var growthPauseMBPerMin: Double
    var pressureCouplingEnabled: Bool
    var pauseProcessTree: Bool
    var pollIntervalSeconds: Double
    var hudMode: HUDMode
    var rules: [AppRule]
    var whitelist: [String]

    static let defaultWhitelist = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "logind", "Halothane", "kernelmanagerd",
    ]

    static var `default`: ConfigData {
        ConfigData(
            percentMode: true, warnPercent: 50, pausePercent: 75,
            warnGB: 20, pauseGB: 50, autoPauseEnabled: false,
            growthDetectionEnabled: true, growthWarnMBPerMin: 2048,
            growthAutoPauseEnabled: false, growthPauseMBPerMin: 4096,
            pressureCouplingEnabled: true, pauseProcessTree: true,
            pollIntervalSeconds: 2, hudMode: .warnAndPause, rules: [], whitelist: defaultWhitelist
        )
    }

    private static let GB = 1_073_741_824.0

    // MARK: Effective settings (rule overrides merged over globals, per field)

    func effectiveWarnBytes(rule: AppRule?) -> Double {
        if percentMode {
            return (rule?.warnPercent ?? warnPercent) / 100 * Double(Hardware.totalBytes)
        }
        return (rule?.warnGB ?? warnGB) * ConfigData.GB
    }

    func effectivePauseBytes(rule: AppRule?) -> Double {
        if percentMode {
            return (rule?.pausePercent ?? pausePercent) / 100 * Double(Hardware.totalBytes)
        }
        return (rule?.pauseGB ?? pauseGB) * ConfigData.GB
    }

    func effectiveAutoPause(rule: AppRule?) -> Bool { rule?.autoPause ?? autoPauseEnabled }
    func effectiveGrowthWarnRate(rule: AppRule?) -> Double { rule?.growthWarnMBPerMin ?? growthWarnMBPerMin }
    func effectiveGrowthAutoPause(rule: AppRule?) -> Bool { rule?.growthAutoPause ?? growthAutoPauseEnabled }
    func effectiveGrowthPauseRate(rule: AppRule?) -> Double { rule?.growthPauseMBPerMin ?? growthPauseMBPerMin }
    func effectivePauseTree(rule: AppRule?) -> Bool { rule?.pauseTree ?? pauseProcessTree }

    func effectivePauseBytes(forName name: String) -> Double {
        effectivePauseBytes(rule: rule(for: name))
    }

    // MARK: Lookups

    func isWhitelisted(_ name: String) -> Bool {
        whitelist.contains { name.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// The winning rule for a process. Among all rules whose match is a
    /// case-insensitive substring of the name, the most specific wins: an exact
    /// match beats any partial, otherwise a longer match beats a shorter one.
    /// At equal specificity, an active Override beats Exempt beats an inactive
    /// (no-op) rule.
    func rule(for name: String) -> AppRule? { ConfigData.resolve(rules, for: name) }

    static func resolve(_ rules: [AppRule], for name: String) -> AppRule? {
        let matches = rules.filter { !$0.match.isEmpty && name.range(of: $0.match, options: .caseInsensitive) != nil }
        guard !matches.isEmpty else { return nil }
        return matches.max { a, b in
            let sa = specificity(a, name: name), sb = specificity(b, name: name)
            if sa != sb { return sa < sb }               // higher specificity wins
            return priorityRank(a) > priorityRank(b)     // lower rank wins
        }
    }

    func isExempt(_ name: String) -> Bool { rule(for: name)?.exempt == true }

    /// A non-exempt, no-override rule that exists specifically to un-exempt a
    /// process otherwise covered by a broader exempt rule (e.g. an exact
    /// "Google Chrome Helper (Renderer)" carving out of "Google Chrome Helper").
    /// Semantically "not exempt", not merely inactive.
    func isCarveOut(_ rule: AppRule) -> Bool {
        guard !rule.exempt, !rule.hasAnyOverride, !rule.match.isEmpty else { return false }
        return ConfigData.resolve(rules.filter { $0.id != rule.id }, for: rule.match)?.exempt == true
    }

    /// Exact (case-insensitive) match is maximally specific; otherwise longer
    /// match string = more specific.
    private static func specificity(_ r: AppRule, name: String) -> Int {
        r.match.caseInsensitiveCompare(name) == .orderedSame ? Int.max : r.match.count
    }

    /// Tie-break priority at equal specificity (lower wins).
    private static func priorityRank(_ r: AppRule) -> Int {
        if r.exempt { return 1 }
        return r.hasAnyOverride ? 0 : 2
    }

    // MARK: Conflicts

    /// Two rules overlap when one match string contains the other (case-
    /// insensitive) — they can match a common process, so resolution order
    /// matters between them.
    static func overlap(_ a: AppRule, _ b: AppRule) -> Bool {
        guard !a.match.isEmpty, !b.match.isEmpty else { return false }
        let am = a.match.lowercased(), bm = b.match.lowercased()
        return am.contains(bm) || bm.contains(am)
    }

    /// Other rules that overlap (conflict) with the given rule.
    func conflicts(for rule: AppRule) -> [AppRule] {
        rules.filter { $0.id != rule.id && ConfigData.overlap($0, rule) }
    }

    /// Of two overlapping rules, the one that takes effect for processes both
    /// match (more specific, then Override > Exempt > inactive).
    static func preferred(_ a: AppRule, _ b: AppRule) -> AppRule {
        if a.match.count != b.match.count { return a.match.count > b.match.count ? a : b }
        return priorityRank(a) <= priorityRank(b) ? a : b
    }

    // MARK: Resilient decoding (missing keys fall back to defaults, so adding
    // settings later doesn't discard a user's saved config).

    init(percentMode: Bool, warnPercent: Double, pausePercent: Double, warnGB: Double,
         pauseGB: Double, autoPauseEnabled: Bool, growthDetectionEnabled: Bool,
         growthWarnMBPerMin: Double, growthAutoPauseEnabled: Bool, growthPauseMBPerMin: Double,
         pressureCouplingEnabled: Bool, pauseProcessTree: Bool, pollIntervalSeconds: Double,
         hudMode: HUDMode, rules: [AppRule], whitelist: [String]) {
        self.percentMode = percentMode; self.warnPercent = warnPercent; self.pausePercent = pausePercent
        self.warnGB = warnGB; self.pauseGB = pauseGB; self.autoPauseEnabled = autoPauseEnabled
        self.growthDetectionEnabled = growthDetectionEnabled; self.growthWarnMBPerMin = growthWarnMBPerMin
        self.growthAutoPauseEnabled = growthAutoPauseEnabled; self.growthPauseMBPerMin = growthPauseMBPerMin
        self.pressureCouplingEnabled = pressureCouplingEnabled; self.pauseProcessTree = pauseProcessTree
        self.pollIntervalSeconds = pollIntervalSeconds; self.hudMode = hudMode
        self.rules = rules; self.whitelist = whitelist
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConfigData.default
        func dbl(_ k: CodingKeys, _ fallback: Double) -> Double { (try? c.decode(Double.self, forKey: k)) ?? fallback }
        func bool(_ k: CodingKeys, _ fallback: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? fallback }
        percentMode = bool(.percentMode, d.percentMode)
        warnPercent = dbl(.warnPercent, d.warnPercent)
        pausePercent = dbl(.pausePercent, d.pausePercent)
        warnGB = dbl(.warnGB, d.warnGB)
        pauseGB = dbl(.pauseGB, d.pauseGB)
        autoPauseEnabled = bool(.autoPauseEnabled, d.autoPauseEnabled)
        growthDetectionEnabled = bool(.growthDetectionEnabled, d.growthDetectionEnabled)
        growthWarnMBPerMin = dbl(.growthWarnMBPerMin, d.growthWarnMBPerMin)
        growthAutoPauseEnabled = bool(.growthAutoPauseEnabled, d.growthAutoPauseEnabled)
        growthPauseMBPerMin = dbl(.growthPauseMBPerMin, d.growthPauseMBPerMin)
        pressureCouplingEnabled = bool(.pressureCouplingEnabled, d.pressureCouplingEnabled)
        pauseProcessTree = bool(.pauseProcessTree, d.pauseProcessTree)
        pollIntervalSeconds = dbl(.pollIntervalSeconds, d.pollIntervalSeconds)
        hudMode = (try? c.decode(HUDMode.self, forKey: .hudMode)) ?? d.hudMode
        rules = (try? c.decode([AppRule].self, forKey: .rules)) ?? d.rules
        whitelist = (try? c.decode([String].self, forKey: .whitelist)) ?? d.whitelist
    }
}
