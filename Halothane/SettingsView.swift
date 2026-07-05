import SwiftUI

/// Settings window. Warn/detection/system settings apply live; pause-causing
/// settings are staged in a draft and only applied on "Apply" (with a live
/// preview of what would be paused, so you can exempt first). Per-app rules use
/// a master-detail editor.
struct SettingsView: View {
    @ObservedObject var config: Config
    @ObservedObject var monitor: Monitor

    @State private var selectedRuleID: AppRule.ID?
    @State private var selectedTab: SettingsTab = .thresholds

    // Staged pause settings (see PauseDraft).
    @State private var draft = PauseDraft()

    enum SettingsTab: Hashable { case thresholds, rules, protected }

    var body: some View {
        TabView(selection: $selectedTab) {
            thresholdsTab
                .tabItem { Label("Thresholds", systemImage: "gauge") }
                .tag(SettingsTab.thresholds)
            rulesTab
                .tabItem { Label("Per-App Rules", systemImage: "list.bullet") }
                .tag(SettingsTab.rules)
            whitelistTab
                .tabItem { Label("Protected", systemImage: "shield") }
                .tag(SettingsTab.protected)
        }
        .frame(width: 540, height: 520)
        .onAppear { draft.loadIfNeeded(from: config); applyPendingRule() }
        .onChange(of: monitor.pendingRuleName) { applyPendingRule() }
        .onReceive(config.objectWillChange) {
            DispatchQueue.main.async {
                config.save()
                monitor.applyConfig()
            }
        }
    }

    /// Honor a request (from the menu/HUD) to configure a specific process:
    /// switch to the rules tab and select a rule for it, creating one if needed.
    private func applyPendingRule() {
        guard let name = monitor.pendingRuleName, !name.isEmpty else { return }
        selectedTab = .rules
        selectedRuleID = config.ensureRule(forName: name)
        DispatchQueue.main.async { monitor.pendingRuleName = nil }
    }

    /// Autocomplete candidates — the same system-wide sample shown in the "All
    /// Processes" window (`monitor.all`), de-duplicated by name and sorted.
    private var processCandidates: [ProcCandidate] {
        var byName: [String: String?] = [:]
        for s in monitor.all where byName[s.name] == nil { byName[s.name] = s.path }
        return byName
            .map { ProcCandidate(name: $0.key, path: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Thresholds

    private var thresholdsTab: some View {
        Form {
            Section {
                Toggle("Set thresholds as % of RAM", isOn: $config.percentMode)
                Text(String(format: "This machine has %.0f GB of RAM. Percent thresholds adapt to whatever machine Halothane runs on.", Hardware.totalGB))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Warn") {
                thresholdControl("Warn when a process exceeds",
                                 percent: $config.warnPercent, gb: $config.warnGB)
                Toggle("Warn on fast memory growth", isOn: $config.growthDetectionEnabled)
                rateRow("Warn above growth rate", value: $config.growthWarnMBPerMin, range: 256...8192)
                    .disabled(!config.growthDetectionEnabled)
            }
            pauseSection
            Section("Alerts") {
                Picker("Floating overlay", selection: $config.hudMode) {
                    ForEach(HUDMode.allCases) { Text($0.label).tag($0) }
                }
                Text("An always-on-top panel listing what needs attention. Dismiss it to snooze until a new process triggers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Pause largest process when system memory is critical",
                       isOn: $config.pressureCouplingEnabled)
                rateRow("Sample interval", value: $config.pollIntervalSeconds, range: 1...10, unit: "s")
            }
        }
        .formStyle(.grouped)
    }

    /// Pause-causing settings are staged: editing them changes `draft`, and they
    /// only reach the daemon on Apply — so dragging the slider doesn't instantly
    /// SIGSTOP everything above it.
    private var pauseSection: some View {
        Section("Pause (freeze with SIGSTOP)") {
            Toggle("Auto-pause on threshold", isOn: $draft.autoPause)
            Text("Off by default — some apps legitimately use lots of memory. Changes here don't take effect until you Apply.")
                .font(.caption).foregroundStyle(.secondary)
            thresholdControl("Pause when a process exceeds",
                             percent: $draft.pausePercent, gb: $draft.pauseGB)
                .disabled(!draft.autoPause)
            Toggle("Pause the whole process tree (parent + children)", isOn: $config.pauseProcessTree)
            Toggle("Auto-pause on runaway growth", isOn: $draft.growthAutoPause)
                .disabled(!config.growthDetectionEnabled)
            rateRow("Pause above growth rate", value: $draft.growthPause, range: 512...16384)
                .disabled(!config.growthDetectionEnabled || !draft.growthAutoPause)

            if !wouldPause.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(wouldPause.count) process\(wouldPause.count == 1 ? "" : "es") would be paused now",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    ForEach(wouldPause) { s in
                        HStack {
                            Text(s.name).lineLimit(1)
                            Text(String(format: "%.1f GB", s.footprintGB))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            Button("Exempt") { exempt(s.name) }.controlSize(.small)
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if draft.isDirty(vs: config) { Text("Unapplied changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Apply pause settings") { applyPauseDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isDirty(vs: config))
            }
        }
    }

    /// Candidate config = applied config with the draft pause settings layered
    /// on, used to preview what would pause.
    private var wouldPause: [ProcSample] {
        var cand = config.data
        cand.autoPauseEnabled = draft.autoPause
        cand.pausePercent = draft.pausePercent
        cand.pauseGB = draft.pauseGB
        cand.growthAutoPauseEnabled = draft.growthAutoPause
        cand.growthPauseMBPerMin = draft.growthPause
        let pausedPIDs = Set(monitor.paused.map(\.pid))
        return monitor.all.filter { !pausedPIDs.contains($0.pid) && PolicyEngine.wouldPause($0, config: cand) }
    }

    private func exempt(_ name: String) {
        config.setExempt(forName: name, true)   // triggers save + push via onReceive
    }

    private func applyPauseDraft() {
        config.autoPauseEnabled = draft.autoPause
        config.pausePercent = draft.pausePercent
        config.pauseGB = draft.pauseGB
        config.growthAutoPauseEnabled = draft.growthAutoPause
        config.growthPauseMBPerMin = draft.growthPause   // triggers save + push
    }

    private func thresholdControl(_ title: String, percent: Binding<Double>, gb: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(config.percentMode
                     ? String(format: "%.0f%%  (%.1f GB)", percent.wrappedValue, percent.wrappedValue / 100 * Hardware.totalGB)
                     : String(format: "%.1f GB", gb.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if config.percentMode { Slider(value: percent, in: 2...95) }
            else { Slider(value: gb, in: 1...max(2, Hardware.totalGB)) }
        }
    }

    private func rateRow(_ title: String, value: Binding<Double>,
                         range: ClosedRange<Double>, unit: String = "MB/min") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(unit == "s" ? String(format: "%.0f s", value.wrappedValue)
                                 : String(format: "%.0f MB/min", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - Per-app rules (master-detail)

    private var rulesTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedRuleID) {
                    ForEach(config.rules) { rule in
                        let conflict = !config.data.conflicts(for: rule).isEmpty
                        HStack {
                            Text((rule.match.isEmpty ? "(unnamed)" : rule.match) + (conflict ? " *" : ""))
                                .lineLimit(1)
                                .foregroundStyle(conflict ? Color.red : Color.primary)
                            Spacer()
                            ruleListChip(rule)
                        }
                        .tag(rule.id)
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Button(action: addRule) {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 22).contentShape(Rectangle())
                    }
                    .help("Add rule")
                    Button(action: removeSelectedRule) {
                        Image(systemName: "minus")
                            .frame(width: 26, height: 22).contentShape(Rectangle())
                    }
                    .help("Remove selected rule")
                    .disabled(selectedRuleID == nil)
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            Group {
                if let idx = config.rules.firstIndex(where: { $0.id == selectedRuleID }) {
                    RuleEditor(rule: $config.rules[idx], config: config, candidates: processCandidates)
                } else {
                    VStack {
                        Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("Select or add a rule").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func ruleListChip(_ rule: AppRule) -> some View {
        if rule.exempt {
            chip("Exempt", .blue)
        } else if rule.hasAnyOverride {
            chip("Override", .orange)
        } else if config.data.isCarveOut(rule) {
            chip("Not exempt", .green)
        } else {
            chip("inactive", .secondary)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.20), in: Capsule()).foregroundStyle(color)
    }

    private func addRule() {
        let rule = AppRule(match: "")
        config.rules.append(rule)
        selectedRuleID = rule.id
    }

    private func removeSelectedRule() {
        config.rules.removeAll { $0.id == selectedRuleID }
        selectedRuleID = nil
    }

    // MARK: - Whitelist

    private var whitelistTab: some View {
        VStack(alignment: .leading) {
            Text("Protected processes are never paused. System-critical ones are included by default.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            List {
                ForEach(config.whitelist, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        if !Config.defaultWhitelist.contains(name) {
                            Button(role: .destructive) {
                                config.whitelist.removeAll { $0 == name }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                ProcessPickerField(text: $newWhitelist, candidates: processCandidates,
                                   placeholder: "Add process name…")
                Button("Add") {
                    let n = newWhitelist.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty && !config.whitelist.contains(n) { config.whitelist.append(n) }
                    newWhitelist = ""
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    @State private var newWhitelist = ""
}

/// Staged copy of the pause-causing settings.
struct PauseDraft {
    var loaded = false
    var autoPause = false
    var pausePercent = 75.0
    var pauseGB = 50.0
    var growthAutoPause = false
    var growthPause = 4096.0

    mutating func loadIfNeeded(from config: Config) {
        guard !loaded else { return }
        autoPause = config.autoPauseEnabled
        pausePercent = config.pausePercent
        pauseGB = config.pauseGB
        growthAutoPause = config.growthAutoPauseEnabled
        growthPause = config.growthPauseMBPerMin
        loaded = true
    }

    func isDirty(vs config: Config) -> Bool {
        autoPause != config.autoPauseEnabled
            || pausePercent != config.pausePercent
            || pauseGB != config.pauseGB
            || growthAutoPause != config.growthAutoPauseEnabled
            || growthPause != config.growthPauseMBPerMin
    }
}
