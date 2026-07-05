import SwiftUI

/// Right-pane editor for one per-app rule. Choose Exempt or Override; in
/// Override mode each global setting has a checkbox — checked overrides it for
/// this app, unchecked inherits the global value (shown greyed). Threshold
/// controls follow the global %/GB unit.
struct RuleEditor: View {
    @Binding var rule: AppRule
    @ObservedObject var config: Config
    let candidates: [ProcCandidate]

    private var totalGB: Double { Hardware.totalGB }

    var body: some View {
        Form {
            Section("Process") {
                ProcessPickerField(text: $rule.match, candidates: candidates)
                Picker("Mode", selection: modeBinding) {
                    Text("Exempt").tag(0)
                    Text("Override").tag(1)
                }
                .pickerStyle(.segmented)
                if rule.exempt {
                    Text("Never warned or paused, regardless of global settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !rule.exempt {
                Section("Overrides") {
                    Text("Check a setting to override it for this app; unchecked inherits the global value.")
                        .font(.caption).foregroundStyle(.secondary)

                    thresholdOverride("Warn above", percent: $rule.warnPercent, gb: $rule.warnGB,
                                      globalPercent: config.warnPercent, globalGB: config.warnGB)
                    boolOverride("Auto-pause on threshold", $rule.autoPause, global: config.autoPauseEnabled)
                    thresholdOverride("Pause above", percent: $rule.pausePercent, gb: $rule.pauseGB,
                                      globalPercent: config.pausePercent, globalGB: config.pauseGB)
                    rateOverride("Warn on growth above", $rule.growthWarnMBPerMin, global: config.growthWarnMBPerMin)
                    boolOverride("Auto-pause on runaway growth", $rule.growthAutoPause, global: config.growthAutoPauseEnabled)
                    rateOverride("Pause on growth above", $rule.growthPauseMBPerMin, global: config.growthPauseMBPerMin)
                    boolOverride("Pause whole process tree", $rule.pauseTree, global: config.pauseProcessTree)
                }
            }

            // Rendered last so it appearing/disappearing as you type doesn't
            // shift (and recreate) the process field above, which would drop
            // keyboard focus.
            conflictNote
        }
        .formStyle(.grouped)
    }

    private var modeBinding: Binding<Int> {
        Binding(get: { rule.exempt ? 0 : 1 }, set: { rule.exempt = ($0 == 0) })
    }

    /// Shown only when this rule's match overlaps another's — explains which
    /// rule wins for processes both match.
    @ViewBuilder private var conflictNote: some View {
        let conflicts = config.data.conflicts(for: rule)
        if !conflicts.isEmpty {
            let winner = ([rule] + conflicts).reduce(rule) { ConfigData.preferred($0, $1) }
            let names = conflicts.map { "“\($0.match)”" }.joined(separator: ", ")
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Overlaps with \(names)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Text("More specific matches win (exact beats partial); at equal specificity Override beats Exempt. For a process matching both, “\(winner.match)” takes effect.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Override rows

    private func boolOverride(_ label: String, _ field: Binding<Bool?>, global: Bool) -> some View {
        let isOn = Binding<Bool>(
            get: { field.wrappedValue != nil },
            set: { field.wrappedValue = $0 ? global : nil }
        )
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(label, isOn: isOn).toggleStyle(.checkbox)
            if field.wrappedValue != nil {
                Toggle("Enabled", isOn: Binding(get: { field.wrappedValue ?? global },
                                                set: { field.wrappedValue = $0 }))
                    .padding(.leading, 18)
            } else {
                inherits(global ? "on" : "off")
            }
        }
    }

    private func rateOverride(_ label: String, _ field: Binding<Double?>, global: Double) -> some View {
        let isOn = Binding<Bool>(
            get: { field.wrappedValue != nil },
            set: { field.wrappedValue = $0 ? global : nil }
        )
        let value = Binding<Double>(get: { field.wrappedValue ?? global },
                                    set: { field.wrappedValue = $0 })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(label, isOn: isOn).toggleStyle(.checkbox)
                Spacer()
                if field.wrappedValue != nil {
                    Text(String(format: "%.0f MB/min", value.wrappedValue))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if field.wrappedValue != nil {
                Slider(value: value, in: 256...16384).padding(.leading, 18)
            } else {
                inherits(String(format: "%.0f MB/min", global))
            }
        }
    }

    private func thresholdOverride(_ label: String, percent: Binding<Double?>, gb: Binding<Double?>,
                                   globalPercent: Double, globalGB: Double) -> some View {
        let active = config.percentMode
        let isOn = Binding<Bool>(
            get: { (active ? percent.wrappedValue : gb.wrappedValue) != nil },
            set: { on in
                if on { if active { percent.wrappedValue = globalPercent } else { gb.wrappedValue = globalGB } }
                else { percent.wrappedValue = nil; gb.wrappedValue = nil }
            }
        )
        let pct = Binding<Double>(get: { percent.wrappedValue ?? globalPercent },
                                  set: { percent.wrappedValue = $0 })
        let g = Binding<Double>(get: { gb.wrappedValue ?? globalGB },
                                set: { gb.wrappedValue = $0 })
        let isSet = (active ? percent.wrappedValue : gb.wrappedValue) != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(label, isOn: isOn).toggleStyle(.checkbox)
                Spacer()
                if isSet {
                    Text(active
                         ? String(format: "%.0f%% (%.1f GB)", pct.wrappedValue, pct.wrappedValue / 100 * totalGB)
                         : String(format: "%.1f GB", g.wrappedValue))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if isSet {
                if active { Slider(value: pct, in: 2...95).padding(.leading, 18) }
                else { Slider(value: g, in: 1...max(2, totalGB)).padding(.leading, 18) }
            } else {
                inherits(active
                         ? String(format: "%.0f%% (%.1f GB)", globalPercent, globalPercent / 100 * totalGB)
                         : String(format: "%.1f GB", globalGB))
            }
        }
    }

    private func inherits(_ text: String) -> some View {
        Text("inherits global: \(text)")
            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 18)
    }
}
