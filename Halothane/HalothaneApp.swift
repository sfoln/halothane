import SwiftUI

struct HalothaneApp: App {
    @StateObject private var config = Config()
    @StateObject private var monitor: Monitor
    private let hud: HUDController

    init() {
        let cfg = Config()
        let mon = Monitor(config: cfg)
        _config = StateObject(wrappedValue: cfg)
        _monitor = StateObject(wrappedValue: mon)
        hud = HUDController(monitor: mon, config: cfg)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor, config: config)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(config: config, monitor: monitor)
        }

        Window("All Processes", id: "processes") {
            ProcessesView(monitor: monitor, config: config)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar status item's label. It's always instantiated (the icon is
/// always on screen), so it's where we capture SwiftUI's `openWindow` action
/// and hand it to the monitor — letting AppKit-hosted views (the floating HUD)
/// open the All Processes window even though they live outside the scene graph.
private struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let headline = monitor.menuBarHeadline {
                Label(headline, systemImage: monitor.menuBarSymbol)
            } else {
                Image(systemName: monitor.menuBarSymbol)
            }
        }
        .onAppear {
            monitor.openProcessesWindow = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "processes")
            }
        }
    }
}

extension Monitor {
    /// SF Symbol reflecting current worst severity / pressure.
    var menuBarSymbol: String {
        if isDisarmed { return "zzz" }
        if !paused.isEmpty { return "pause.circle.fill" }
        switch status {
        case .pause: return "pause.circle.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .normal: return pressureLevel == .normal ? "memorychip" : "memorychip.fill"
        }
    }
}
