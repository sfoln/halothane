import SwiftUI

/// Detailed, resizable window listing all sampled processes with their
/// footprint, growth, effective pause threshold, per-app rule status, and quick
/// actions (pause/resume, exempt). Opened from the menu's "All processes"
/// button. Far more room than the menu popover.
struct ProcessesView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var config: Config
    @State private var search = ""

    private var rows: [ProcSample] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return monitor.all }
        return monitor.all.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { s in
                        ProcessDetailRow(sample: s, config: config, monitor: monitor)
                        Divider()
                    }
                }
            }
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 460)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Label(monitor.backendIsRoot ? "All processes — system-wide" : "All processes — current user",
                      systemImage: monitor.backendIsRoot ? "checkmark.shield.fill" : "person.fill")
                    .font(.headline)
                    .foregroundStyle(monitor.backendIsRoot ? .green : .secondary)
                Spacer()
                Text("\(rows.count) shown").foregroundStyle(.secondary).font(.caption)
                TextField("Filter…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            columnHeader
        }
        .padding(10)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Process").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text("PID").frame(width: 56, alignment: .trailing)
            Text("User").frame(width: 50, alignment: .trailing)
            Text("Memory").frame(width: 72, alignment: .trailing)
            Text("Growth").frame(width: 78, alignment: .trailing)
            Text("Pause at").frame(width: 80, alignment: .trailing)
            Text("Rule").frame(width: 90, alignment: .leading)
            Text("Actions").frame(width: 240, alignment: .leading)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct ProcessDetailRow: View {
    let sample: ProcSample
    @ObservedObject var config: Config
    @ObservedObject var monitor: Monitor

    private var rule: AppRule? { config.data.rule(for: sample.name) }
    private var isPaused: Bool { monitor.paused.contains { $0.pid == sample.pid } }
    private var autoPauses: Bool { config.data.effectiveAutoPause(rule: rule) && rule?.exempt != true }
    private var pauseThresholdGB: Double { config.data.effectivePauseBytes(rule: rule) / 1_073_741_824.0 }

    var body: some View {
        HStack(spacing: 8) {
            Text(sample.name).lineLimit(1).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isPaused ? .red : .primary)
            Text("\(sample.pid)").frame(width: 56, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
            Text("\(sample.uid)").frame(width: 50, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
            Text(String(format: "%.1f GB", sample.footprintGB))
                .frame(width: 72, alignment: .trailing).monospacedDigit()
            Text(sample.growthMBPerMin.map { String(format: "%.0f MB/m", $0) } ?? "—")
                .frame(width: 78, alignment: .trailing).monospacedDigit()
                .foregroundStyle((sample.growthMBPerMin ?? 0) > 200 ? .orange : .secondary)
            Text(autoPauses ? String(format: "%.0f GB", pauseThresholdGB) : "—")
                .frame(width: 80, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
            ruleChip.frame(width: 90, alignment: .leading)
            ProcessActions(name: sample.name, pid: sample.pid, config: config, monitor: monitor)
                .frame(width: 240, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isPaused ? Color.red.opacity(0.08) : .clear)
    }

    @ViewBuilder private var ruleChip: some View {
        if isPaused {
            chip("paused", .red)
        } else if rule?.exempt == true {
            chip("exempt", .blue)
        } else if rule?.hasAnyOverride == true {
            chip("override", .orange)
        } else if let r = rule, config.data.isCarveOut(r) {
            chip("not exempt", .green)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.22), in: Capsule()).foregroundStyle(color)
    }
}
