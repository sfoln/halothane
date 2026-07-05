import Foundation

/// Pure decision logic: given a sample and config, decide warn vs pause.
/// Kept side-effect-free so it's trivial to unit test and identical whether
/// it runs in-process (Phase 1) or in the daemon (Phase 2).
enum PolicyEngine {

    private static let GB = 1_073_741_824.0
    private static let MBPerMin = 1_048_576.0 / 60.0  // bytes/sec per MB/min

    static func evaluate(_ s: ProcSample, config: ConfigData) -> Decision {
        // Exemptions first.
        if config.isWhitelisted(s.name) {
            return Decision(severity: .normal, reason: .none)
        }
        let rule = config.rule(for: s.name)
        if rule?.exempt == true {
            return Decision(severity: .normal, reason: .none)
        }

        let warnBytes = config.effectiveWarnBytes(rule: rule)
        let pauseBytes = config.effectivePauseBytes(rule: rule)
        let mayPause = config.effectiveAutoPause(rule: rule)

        let fp = Double(s.footprint)
        let rate = s.growthRate ?? 0  // bytes/sec

        // Absolute footprint: pause dominates warn.
        if fp >= pauseBytes && mayPause {
            return Decision(severity: .pause, reason: .footprintPause)
        }

        // Growth-rate.
        if config.growthDetectionEnabled, s.growthRate != nil {
            let warnRate = config.effectiveGrowthWarnRate(rule: rule) * MBPerMin
            let pauseRate = config.effectiveGrowthPauseRate(rule: rule) * MBPerMin
            if rate >= pauseRate && config.effectiveGrowthAutoPause(rule: rule) && mayPause {
                return Decision(severity: .pause, reason: .growthPause)
            }
            if fp >= warnBytes {
                return Decision(severity: .warn, reason: .footprintWarn)
            }
            if rate >= warnRate {
                return Decision(severity: .warn, reason: .growthWarn)
            }
        } else if fp >= warnBytes {
            return Decision(severity: .warn, reason: .footprintWarn)
        }

        return Decision(severity: .normal, reason: .none)
    }

    /// Would this process be paused right now under the given config? Used by
    /// the Settings "would pause now" preview so the user can exempt processes
    /// before committing a lower pause threshold.
    static func wouldPause(_ s: ProcSample, config: ConfigData) -> Bool {
        evaluate(s, config: config).severity == .pause
    }
}
