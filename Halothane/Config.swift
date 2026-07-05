import Foundation
import Combine

/// Per-application override. Keyed by executable name (substring, case-
/// insensitive). A rule can raise thresholds for apps that legitimately use
/// lots of memory, exempt them entirely, or opt them into auto-pause.
/// A per-application rule. Either fully `exempt` (never warn or pause), or an
/// override: any subset of global settings can be overridden for matching
/// processes; a `nil` override field means "inherit the global value".
/// Threshold values are stored in both units; the active one follows the global
/// `percentMode` toggle.
struct AppRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var match: String
    var exempt: Bool = false

    // Per-setting overrides (nil = inherit global).
    var warnPercent: Double?
    var warnGB: Double?
    var autoPause: Bool?
    var pausePercent: Double?
    var pauseGB: Double?
    var growthWarnMBPerMin: Double?
    var growthAutoPause: Bool?
    var growthPauseMBPerMin: Double?
    var pauseTree: Bool?

    /// True if this rule overrides at least one setting (vs. a no-op rule).
    var hasAnyOverride: Bool {
        warnPercent != nil || warnGB != nil || autoPause != nil || pausePercent != nil
            || pauseGB != nil || growthWarnMBPerMin != nil || growthAutoPause != nil
            || growthPauseMBPerMin != nil || pauseTree != nil
    }
}

/// SwiftUI-facing settings object. Holds the individual `@Published` fields the
/// Settings UI binds to, and bridges to/from the value-type `ConfigData` that
/// the engine and XPC layer use. Persists locally for the UI; the daemon keeps
/// the authoritative copy (pushed via XPC).
final class Config: ObservableObject {
    @Published var percentMode: Bool
    @Published var warnPercent: Double
    @Published var pausePercent: Double
    @Published var warnGB: Double
    @Published var pauseGB: Double
    @Published var autoPauseEnabled: Bool
    @Published var growthDetectionEnabled: Bool
    @Published var growthWarnMBPerMin: Double
    @Published var growthAutoPauseEnabled: Bool
    @Published var growthPauseMBPerMin: Double
    @Published var pressureCouplingEnabled: Bool
    @Published var pauseProcessTree: Bool
    @Published var pollIntervalSeconds: Double
    @Published var hudMode: HUDMode
    @Published var rules: [AppRule]
    @Published var whitelist: [String]

    static let defaultWhitelist = ConfigData.defaultWhitelist

    init() {
        let d = Config.loadData() ?? .default
        percentMode = d.percentMode; warnPercent = d.warnPercent; pausePercent = d.pausePercent
        warnGB = d.warnGB; pauseGB = d.pauseGB; autoPauseEnabled = d.autoPauseEnabled
        growthDetectionEnabled = d.growthDetectionEnabled; growthWarnMBPerMin = d.growthWarnMBPerMin
        growthAutoPauseEnabled = d.growthAutoPauseEnabled; growthPauseMBPerMin = d.growthPauseMBPerMin
        pressureCouplingEnabled = d.pressureCouplingEnabled; pauseProcessTree = d.pauseProcessTree
        pollIntervalSeconds = d.pollIntervalSeconds; hudMode = d.hudMode
        rules = d.rules; whitelist = d.whitelist
    }

    /// Value snapshot for the engine / XPC.
    var data: ConfigData {
        ConfigData(
            percentMode: percentMode, warnPercent: warnPercent, pausePercent: pausePercent,
            warnGB: warnGB, pauseGB: pauseGB, autoPauseEnabled: autoPauseEnabled,
            growthDetectionEnabled: growthDetectionEnabled, growthWarnMBPerMin: growthWarnMBPerMin,
            growthAutoPauseEnabled: growthAutoPauseEnabled, growthPauseMBPerMin: growthPauseMBPerMin,
            pressureCouplingEnabled: pressureCouplingEnabled, pauseProcessTree: pauseProcessTree,
            pollIntervalSeconds: pollIntervalSeconds, hudMode: hudMode, rules: rules, whitelist: whitelist
        )
    }

    // MARK: - Rule helpers

    /// Raise (or create) a per-app pause threshold for a specific process,
    /// expressed in the active unit (percent of RAM, or absolute GB). Used by
    /// the inline "resume above…" control and the detail view. Returns nothing;
    /// callers push config afterward.
    func setPauseThreshold(forName name: String, value: Double) {
        let idx = rules.firstIndex { $0.match == name }
        var rule = idx.map { rules[$0] } ?? AppRule(match: name)
        rule.autoPause = true
        rule.exempt = false
        if percentMode { rule.pausePercent = value; rule.pauseGB = nil }
        else { rule.pauseGB = value; rule.pausePercent = nil }
        if let idx { rules[idx] = rule } else { rules.append(rule) }
    }

    /// Toggle a process's exempt status. Uses an exact-match rule so it can both
    /// exempt a process and *un-exempt* one that's only exempt via a broader rule
    /// (by adding a more-specific carve-out rule, which wins by specificity).
    func setExempt(forName name: String, _ exempt: Bool) {
        let exactIdx = rules.firstIndex { $0.match.caseInsensitiveCompare(name) == .orderedSame }

        if exempt {
            if let i = exactIdx { rules[i].exempt = true }
            else { var r = AppRule(match: name); r.exempt = true; rules.append(r) }
            return
        }

        // Un-exempt.
        if let i = exactIdx {
            rules[i].exempt = false
            // If the exact rule now does nothing and nothing broader exempts the
            // process, it's dead weight — remove it.
            if !rules[i].hasAnyOverride {
                let id = rules[i].id
                let others = rules.filter { $0.id != id }
                if ConfigData.resolve(others, for: name)?.exempt != true {
                    rules.removeAll { $0.id == id }
                }
            }
        } else {
            // No exact rule, so it's exempt via a broader rule — add an exact
            // non-exempt carve-out that overrides it.
            rules.append(AppRule(match: name))
        }
    }

    /// Find an existing exact-match rule for a process, or create an empty one,
    /// returning its id. Used when the user clicks a process to configure it —
    /// the Settings rules tab then selects this rule for editing.
    @discardableResult
    func ensureRule(forName name: String) -> AppRule.ID {
        if let i = rules.firstIndex(where: { $0.match.caseInsensitiveCompare(name) == .orderedSame }) {
            return rules[i].id
        }
        let r = AppRule(match: name)
        rules.append(r)
        return r.id
    }

    // MARK: - Persistence (local UI copy)

    private static let key = "Halothane.config.v1"

    func save() {
        if let json = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(json, forKey: Config.key)
        }
    }

    private static func loadData() -> ConfigData? {
        guard let json = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ConfigData.self, from: json)
    }
}
