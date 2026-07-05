import SwiftUI

/// Contents of the floating always-on-top overlay: a single consolidated card
/// listing every process currently warning or paused (with a short linger), and
/// the same actions as elsewhere. Driven by `Monitor.hudItems`; the
/// `HUDController` decides when to show/hide the panel.
struct HUDView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var config: Config
    let onDismiss: () -> Void

    var body: some View {
        let items = monitor.hudItems
        let anyPaused = items.contains { $0.paused }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: anyPaused ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(anyPaused ? .red : .orange)
                Text("Halothane").bold()
                Image(systemName: "rectangle.expand.vertical")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Dismiss")
            }
            .contentShape(Rectangle())
            .onTapGesture { openDetails() }
            .help("Show all processes")

            ForEach(items) { item in
                row(item)
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }

    /// Open the All Processes window — gives the HUD's warnings full context and
    /// makes clear it belongs to Halothane. (The menu-bar popover itself can't be
    /// opened programmatically by macOS, so this is the closest equivalent.)
    private func openDetails() { monitor.openProcessesWindow?() }

    private func row(_ item: HUDItem) -> some View {
        let color: Color = item.paused ? .red : .orange
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.paused ? "paused" : "warning").font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.22), in: Capsule()).foregroundStyle(color)
                Text(item.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                Text(String(format: "%.1f GB", item.footprintGB))
                    .font(.callout).bold().monospacedDigit().foregroundStyle(color)
            }
            .contentShape(Rectangle())
            .onTapGesture { openDetails() }
            ProcessActions(name: item.name, pid: item.pid, config: config, monitor: monitor)
        }
        .padding(8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
