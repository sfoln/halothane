import SwiftUI

/// A single compact row for a paused process: red-tinted, normal height, with a
/// "paused" badge and small inline action buttons. Clicking Resume, when the
/// process is still above the threshold that would re-pause it, expands an
/// inline slider (under the row, not a popup) to raise that app's pause
/// threshold; Resume only enables once the threshold is above the current
/// footprint.
struct PausedRowView: View {
    let p: PausedProcess
    @ObservedObject var config: Config
    @ObservedObject var monitor: Monitor

    @State private var editing = false
    @State private var threshold: Double = 0   // in the active unit (% or GB)

    private let GB = 1_073_741_824.0
    private var footprintBytes: Double { Double(p.footprintAtPause) }
    private var thresholdBytes: Double {
        config.percentMode ? threshold / 100 * Double(Hardware.totalBytes) : threshold * GB
    }
    private var canResume: Bool { thresholdBytes > footprintBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pause.fill").font(.caption).foregroundStyle(.red)
                Text(p.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                ProcessActions(name: p.name, pid: p.pid, config: config, monitor: monitor,
                               onResumeOverride: { onResume() })
                Text(String(format: "%.1f GB", p.footprintGB))
                    .font(.callout).bold().monospacedDigit()
                    .foregroundStyle(.red)
            }
            if editing { inlineEditor }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "Using %.1f GB. Raise this app's pause threshold above that to resume — otherwise it re-pauses immediately.", p.footprintGB))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if config.percentMode {
                    Slider(value: $threshold, in: 1...100)
                } else {
                    Slider(value: $threshold, in: 0.5...max(2, Hardware.totalGB))
                }
                Text(thresholdLabel)
                    .font(.caption2).monospacedDigit()
                    .frame(width: 96, alignment: .trailing)
                    .foregroundStyle(canResume ? Color.primary : Color.red)
                Button("Resume") { confirmResume() }
                    .controlSize(.small)
                    .disabled(!canResume)
            }
        }
        .padding(.top, 2)
    }

    private var thresholdLabel: String {
        config.percentMode
            ? String(format: "%.0f%% (%.1f GB)", threshold, threshold / 100 * Hardware.totalGB)
            : String(format: "%.1f GB", threshold)
    }

    private func onResume() {
        // If it's already below the threshold that would re-pause it, just resume.
        let effPause = config.data.effectivePauseBytes(forName: p.name)
        if footprintBytes < effPause {
            monitor.resume(p)
            return
        }
        // Otherwise open the inline raise-threshold editor, starting at the
        // current effective threshold (which is below the footprint).
        threshold = config.percentMode
            ? effPause / Double(Hardware.totalBytes) * 100
            : effPause / GB
        editing = true
    }

    private func confirmResume() {
        config.setPauseThreshold(forName: p.name, value: threshold)
        config.save()
        monitor.applyConfig()   // ordered before resume over XPC, so it won't re-pause
        monitor.resume(p)
        editing = false
    }
}
