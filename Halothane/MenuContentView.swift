import SwiftUI

/// The dropdown shown from the menu-bar icon: live top offenders, any paused
/// processes (with Resume / Quit / Force-kill), and a recent activity log.
struct MenuContentView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var config: Config
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if monitor.isDisarmed {
                disarmedBanner
            }

            if !monitor.paused.isEmpty {
                Divider()
                pausedSection
            }

            Divider()
            topSection

            if !monitor.notificationsAuthorized {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Notifications are off — enable for alerts", systemImage: "bell.slash")
                        .font(.caption2).foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
            }

            if !monitor.warnings.isEmpty {
                Divider()
                warningsSection
            } else if let recent = monitor.log.first {
                Divider()
                Text(recent.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { monitor.refreshNotificationAuth() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "h.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.halothaneTeal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Halothane").font(.headline)
                Label(monitor.backendIsRoot ? "system-wide (all accounts)" : "this user only",
                      systemImage: monitor.backendIsRoot ? "checkmark.shield.fill" : "person.fill")
                    .font(.caption2)
                    .foregroundStyle(monitor.backendIsRoot ? .green : .secondary)
            }
            Spacer()
            pressureBadge
        }
    }

    @ViewBuilder private var pressureBadge: some View {
        switch monitor.pressureLevel {
        case .normal: EmptyView()
        case .warning:
            Label("pressure", systemImage: "gauge.medium")
                .font(.caption2).foregroundStyle(.orange)
        case .critical:
            Label("critical", systemImage: "gauge.high")
                .font(.caption2).foregroundStyle(.red)
        }
    }

    private var disarmedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "zzz").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Monitoring paused").font(.caption).bold()
                Text(monitor.disarmedRemainingText + " · affects all accounts")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { monitor.resumeMonitoring() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var pausedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paused").font(.caption).foregroundStyle(.secondary)
            ForEach(monitor.paused) { p in
                PausedRowView(p: p, config: config, monitor: monitor)
            }
        }
    }

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top memory").font(.caption).foregroundStyle(.secondary)
            if monitor.top.isEmpty {
                Text(monitor.running ? "Sampling…" : "Not running")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.top) { s in
                let exempt = config.data.isExempt(s.name)
                let overWarn = Double(s.footprint) >= config.data.effectiveWarnBytes(rule: config.data.rule(for: s.name))
                Button { configure(s.name) } label: {
                    HStack {
                        Text(s.name).lineLimit(1)
                        if exempt {
                            Text("exempt").font(.caption2)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.green.opacity(0.22), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        if let mb = s.growthMBPerMin, mb > 200, !exempt {
                            Image(systemName: "arrow.up.right")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Text(String(format: "%.1f GB", s.footprintGB))
                            .monospacedDigit()
                            .foregroundStyle(exempt ? Color.blue : (overWarn ? Color.orange : Color.primary))
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Configure a rule for \(s.name)")
            }

            Button { openProcesses() } label: {
                HStack {
                    Image(systemName: "rectangle.expand.vertical")
                    Text("View all processes")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
    }

    /// Every process currently warning — not just the most recent. Each row is
    /// clickable to jump straight to a per-app rule for it.
    private var warningsSection: some View {
        let warns = monitor.warnings
        let shown = warns.prefix(6)
        return VStack(alignment: .leading, spacing: 4) {
            Label("\(warns.count) warning\(warns.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            ForEach(shown) { s in
                Button { configure(s.name) } label: {
                    HStack(spacing: 6) {
                        Text(s.name).lineLimit(1)
                        let reason = monitor.warnReason(s)
                        if !reason.isEmpty {
                            Text(reason).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f GB", s.footprintGB))
                            .monospacedDigit().foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Configure a rule for \(s.name)")
            }
            if warns.count > shown.count {
                Text("+\(warns.count - shown.count) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if monitor.isDisarmed {
                Button {
                    monitor.resumeMonitoring()
                } label: { Label("Resume monitoring", systemImage: "play.fill") }
            } else {
                Menu {
                    Button("For 15 minutes") { monitor.pauseMonitoring(for: 15 * 60) }
                    Button("For 1 hour")     { monitor.pauseMonitoring(for: 60 * 60) }
                    Button("For 4 hours")    { monitor.pauseMonitoring(for: 4 * 60 * 60) }
                    Divider()
                    Button("Until I resume") { monitor.pauseMonitoring(for: nil) }
                } label: {
                    Label("Pause monitoring", systemImage: "pause.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Button("Settings…") { openSettings() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }

    /// Accessory (LSUIElement) apps don't auto-activate, so opening Settings
    /// from a menu-bar popover appears to do nothing. Use the SwiftUI
    /// `openSettings` action (the legacy `showSettingsWindow:` selector is a
    /// no-op on recent macOS), activate the app, and defer one runloop tick so
    /// the popover's dismissal doesn't swallow the action. Finally, force the
    /// Settings window in front in case it opened ordered-behind.
    /// Open the detailed all-processes window (accessory app needs activation).
    private func openProcesses() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "processes")
        }
    }

    /// Jump to Settings → Per-App Rules with a rule for `name` selected (created
    /// if needed), so the user can exempt or override it.
    private func configure(_ name: String) {
        monitor.pendingRuleName = name
        openSettings()
    }

    private func openSettings() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            openSettingsAction()
            DispatchQueue.main.async {
                if let win = NSApp.windows.first(where: { $0.title == "Halothane Settings" || $0.identifier?.rawValue.contains("Settings") == true }) {
                    win.makeKeyAndOrderFront(nil)
                } else {
                    NSApp.windows.last?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
