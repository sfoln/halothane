import SwiftUI

/// Consistent labeled action buttons for a process, used in both the menu's
/// paused row and the All Processes window. Running processes get Pause +
/// Exempt; paused processes get Resume / Quit / Force Kill + Exempt.
struct ProcessActions: View {
    let name: String
    let pid: pid_t
    @ObservedObject var config: Config
    @ObservedObject var monitor: Monitor
    /// When set, Resume calls this instead of resuming directly — lets the menu
    /// paused row open its raise-threshold slider first.
    var onResumeOverride: (() -> Void)? = nil

    private var pausedEntry: PausedProcess? { monitor.paused.first { $0.pid == pid } }
    private var isExempt: Bool { config.data.rule(for: name)?.exempt == true }
    private var isWhitelisted: Bool { config.data.isWhitelisted(name) }

    var body: some View {
        HStack(spacing: 6) {
            if let p = pausedEntry {
                button("Resume", "play.fill", .green) { onResumeOverride?() ?? monitor.resume(p) }
                button("Quit", "stop.fill", .secondary) { monitor.quit(p) }
                button("Force Kill", "bolt.fill", .red) { monitor.forceKill(p) }
            } else {
                button("Pause", "pause.fill", .secondary) { monitor.pauseNow(pid) }
                    .disabled(isWhitelisted)
            }
            button(isExempt ? "Unexempt" : "Exempt", "shield.fill", isExempt ? .blue : .secondary) {
                config.setExempt(forName: name, !isExempt)
                config.save(); monitor.applyConfig()
            }
        }
    }

    private func button(_ title: String, _ symbol: String, _ tint: Color,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(tint)
            .help(title)
    }
}
