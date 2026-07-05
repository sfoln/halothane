import AppKit
import SwiftUI
import Combine

/// Manages the floating overlay panel: a borderless, non-activating, always-on-
/// top NSPanel that appears top-right when processes need attention and hides
/// when they don't. Dismissing snoozes it until a *new* offender appears.
@MainActor
final class HUDController {
    private let monitor: Monitor
    private let config: Config
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDView>?
    private var cancellables: Set<AnyCancellable> = []

    /// Offender PIDs the user dismissed; stay hidden until the set grows.
    private var snoozed: Set<pid_t>?

    init(monitor: Monitor, config: Config) {
        self.monitor = monitor
        self.config = config
        // Re-evaluate whenever monitor state or settings change. objectWillChange
        // fires before the value updates, so defer a tick.
        monitor.objectWillChange
            .merge(with: config.objectWillChange)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
        update()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(monitor: monitor, config: config,
                                                   onDismiss: { [weak self] in self?.dismiss() }))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        self.hostingView = host
        self.panel = p
        return p
    }

    private func update() {
        let pids = Set(monitor.hudItems.map(\.pid))

        if pids.isEmpty {
            snoozed = nil
            panel?.orderOut(nil)
            return
        }
        // Snoozed unless a new offender has appeared since dismissal.
        if let snoozed, pids.isSubset(of: snoozed) {
            panel?.orderOut(nil)
            return
        }
        snoozed = nil
        show()
    }

    private func show() {
        let panel = ensurePanel()
        // Size to content, then pin to the top-right of the active screen.
        if let host = hostingView {
            host.layoutSubtreeIfNeeded()
            let h = max(1, host.fittingSize.height)
            panel.setContentSize(NSSize(width: 360, height: h))
        }
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let margin: CGFloat = 12
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - margin,
                                         y: vf.maxY - panel.frame.height - margin))
        }
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        snoozed = Set(monitor.hudItems.map(\.pid))
        panel?.orderOut(nil)
    }
}
