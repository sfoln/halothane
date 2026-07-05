import Foundation
import Combine
import AppKit
import UserNotifications

/// The UI's view-model. Owns a `SupervisorBackend` — the root daemon over XPC
/// when available, otherwise an in-process engine for the current user — and
/// republishes its snapshots for SwiftUI. Also posts user notifications in this
/// login session (the daemon can't, since it has no GUI session).
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var top: [ProcSample] = []
    @Published private(set) var all: [ProcSample] = []
    @Published private(set) var paused: [PausedProcess] = []
    @Published private(set) var pressureLevel: MemoryPressureMonitor.Level = .normal
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var status: Severity = .normal
    @Published private(set) var backendIsRoot = false
    @Published var running = false
    @Published private(set) var notificationsAuthorized = true

    /// When monitoring is paused ("disarmed"), the auto-resume time (or
    /// `Date.distantFuture` for indefinite). `nil` = armed/active.
    @Published private(set) var disarmedUntil: Date?
    var isDisarmed: Bool { disarmedUntil != nil }

    /// The floating HUD's attention set, maintained with a short linger so
    /// transient warns don't flash away. Drives both the panel's visibility and
    /// its contents (so they always agree).
    @Published private(set) var hudItems: [HUDItem] = []

    /// Set when the user clicks a process (in the menu or HUD) to configure it.
    /// The Settings window observes this, switches to the rules tab, and selects
    /// (creating if needed) the matching rule, then clears it.
    @Published var pendingRuleName: String?

    /// Opens the "All Processes" window. Populated by the menu-bar scene (which
    /// has the SwiftUI `openWindow` action) so AppKit-hosted views like the HUD
    /// can request it. Always invoked on the main actor.
    var openProcessesWindow: (() -> Void)?

    let config: Config

    private var backend: SupervisorBackend!
    private var remote: RemoteBackend?
    private var receivedSnapshot = false
    private var cancellables: Set<AnyCancellable> = []

    /// pid -> last time it qualified for the HUD. Kept for the linger window.
    private var hudSeen: [pid_t: Date] = [:]
    private let hudLinger: TimeInterval = 15

    init(config: Config) {
        self.config = config
        configureNotifications()
        // Recompute the HUD set promptly when settings change (e.g. exempting a
        // process should drop it without waiting for the next snapshot).
        config.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshHUD() } }
            .store(in: &cancellables)
        connect()
    }

    /// Prefer the privileged daemon; fall back to in-process (current user).
    private func connect() {
        let remote = RemoteBackend()
        remote.onUnavailable = { [weak self] in self?.fallbackToLocal() }
        bind(remote)
        _ = remote.connect()
        self.remote = remote
        self.backend = remote
        startBackend()
        // If no snapshot ever arrives, the daemon isn't installed/reachable —
        // fall back to the in-process engine for the current user.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, !self.receivedSnapshot else { return }
            self.fallbackToLocal()
        }
    }

    private func fallbackToLocal() {
        guard !(backend is LocalBackend) else { return }
        remote?.disconnect()
        remote = nil
        let local = LocalBackend(config: config.data)
        bind(local)
        backend = local
        startBackend()
    }

    private func bind(_ b: SupervisorBackend) {
        b.onSnapshot = { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
        b.onEvent = { [weak self] ev in
            Task { @MainActor in self?.handle(ev) }
        }
    }

    private func startBackend() {
        running = true
        backend.updateConfig(config.data)
        backend.start()
    }

    private func apply(_ snap: Snapshot) {
        receivedSnapshot = true
        top = snap.top
        all = snap.all
        paused = snap.paused
        pressureLevel = MemoryPressureMonitor.Level(rawValue: snap.pressure) ?? .normal
        status = snap.status
        log = snap.log
        backendIsRoot = snap.backendIsRoot
        disarmedUntil = snap.disarmedUntil
        refreshHUD()
    }

    /// Rebuild `hudItems`: currently-qualifying processes, plus ones that
    /// qualified within the linger window and are still running and not exempt.
    /// Exempt / gone / paused-resolved drop promptly.
    private func refreshHUD() {
        let mode = config.hudMode
        guard mode != .off, !isDisarmed else { hudItems = []; hudSeen.removeAll(); return }
        let now = Date()
        let cfg = config.data
        let pausedPIDs = Set(paused.map(\.pid))
        let byPID = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // Record processes warning right now.
        if mode == .warnAndPause {
            for s in all where !pausedPIDs.contains(s.pid)
                && !cfg.isExempt(s.name)
                && PolicyEngine.evaluate(s, config: cfg).severity == .warn {
                hudSeen[s.pid] = now
            }
        }

        // Warn rows: still running, not paused, not exempt, within linger.
        var warns: [HUDItem] = []
        var kept: [pid_t: Date] = [:]
        for (pid, t) in hudSeen {
            guard let s = byPID[pid], !pausedPIDs.contains(pid), !cfg.isExempt(s.name) else { continue }
            guard now.timeIntervalSince(t) <= hudLinger else { continue }
            kept[pid] = t
            warns.append(HUDItem(pid: pid, name: s.name, footprint: s.footprint, paused: false))
        }
        hudSeen = kept

        // Stable order: dictionary iteration above is non-deterministic, which
        // makes rows swap places every tick. Sort by footprint (then pid).
        warns.sort { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
        let pausedItems = paused
            .sorted { $0.footprintAtPause != $1.footprintAtPause ? $0.footprintAtPause > $1.footprintAtPause : $0.pid < $1.pid }
            .map { HUDItem(pid: $0.pid, name: $0.name, footprint: $0.footprintAtPause, paused: true) }
        hudItems = pausedItems + warns
    }

    // MARK: - Commands

    func resume(_ p: PausedProcess) { backend.resume(pid: p.pid) }
    func quit(_ p: PausedProcess)   { backend.quit(pid: p.pid) }
    func forceKill(_ p: PausedProcess) { backend.kill(pid: p.pid) }
    func pauseNow(_ pid: pid_t) { backend.pauseNow(pid: pid) }

    /// Push current settings to the backend (called when settings change).
    func applyConfig() { backend.updateConfig(config.data) }
    func reschedule() { backend.updateConfig(config.data) }

    /// Pause monitoring globally (the shared engine, both accounts). `duration ==
    /// nil` pauses until the user resumes; otherwise it auto-resumes after it.
    func pauseMonitoring(for duration: TimeInterval?) {
        let until = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        disarmedUntil = until                 // optimistic; confirmed by next snapshot
        backend.setDisarm(until: until)
        refreshHUD()
    }

    func resumeMonitoring() {
        disarmedUntil = nil
        backend.setDisarm(until: nil)
        refreshHUD()
    }

    /// Anything beyond ~5 years out is treated as the "until I resume" sentinel.
    private var disarmIsIndefinite: Bool {
        guard let until = disarmedUntil else { return false }
        return until.timeIntervalSinceNow > 5 * 365 * 24 * 3600
    }

    /// Human-readable remaining time for the paused banner.
    var disarmedRemainingText: String {
        guard disarmedUntil != nil else { return "" }
        if disarmIsIndefinite { return "Paused until you resume" }
        let secs = max(0, Int(disarmedUntil!.timeIntervalSinceNow))
        let mins = (secs + 59) / 60
        if mins >= 60 { return "Resumes in \(mins / 60)h \(mins % 60)m" }
        return mins <= 1 ? "Resumes in under a minute" : "Resumes in \(mins)m"
    }

    // Retained for menu compatibility; monitoring always runs now.
    func start() { running = true }
    func stop() { running = false }

    // MARK: - Notifications (this session only)

    private func handle(_ ev: SupervisorEvent) {
        switch ev.kind {
        case .warn:
            notify(title: ev.title, body: ev.body, identifier: "warn-\(ev.pid)", urgent: false)
        case .paused:
            notify(title: ev.title, body: ev.body, identifier: "paused-\(ev.pid)", urgent: true)
        case .resumed, .killed, .info:
            break
        }
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotifDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            self.refreshNotificationAuth()
        }
    }

    /// Re-query the live authorization status — called on launch and whenever
    /// the menu opens, so toggling it in System Settings is reflected without a
    /// restart.
    func refreshNotificationAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized
                  || settings.authorizationStatus == .provisional
            Task { @MainActor in self.notificationsAuthorized = ok }
        }
    }

    private func notify(title: String, body: String, identifier: String, urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = urgent ? .defaultCritical : .default
        // Time-sensitive pauses break through Focus where the entitlement allows;
        // otherwise this gracefully falls back to an active banner.
        content.interruptionLevel = urgent ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    // MARK: - Attention sets (for the menu)

    /// Every process currently in a warn state (not paused, not exempt). The
    /// menu lists all of these, not just the most recent — there can be several
    /// at once.
    var warnings: [ProcSample] {
        guard !isDisarmed else { return [] }
        let cfg = config.data
        let pausedPIDs = Set(paused.map(\.pid))
        return all.filter {
            !pausedPIDs.contains($0.pid)
                && PolicyEngine.evaluate($0, config: cfg).severity == .warn
        }
    }

    /// Short reason label for a warning row (e.g. "high memory", "growing fast").
    func warnReason(_ s: ProcSample) -> String {
        PolicyEngine.evaluate(s, config: config.data).reason.label
    }

    // MARK: - Menu-bar headline

    /// Short text shown next to the menu-bar icon when something needs
    /// attention — visible at a glance without depending on notifications.
    var menuBarHeadline: String? {
        if isDisarmed { return "Paused" }
        if let p = paused.first {
            let name = Self.short(p.name)
            return paused.count > 1 ? "\(name) +\(paused.count - 1)" : name
        }
        let warns = warnings
        if let s = warns.first {
            let head = String(format: "%@ %.0fGB", Self.short(s.name), s.footprintGB)
            return warns.count > 1 ? "\(head) +\(warns.count - 1)" : head
        }
        return nil
    }

    private static func short(_ name: String) -> String {
        name.count > 14 ? String(name.prefix(13)) + "…" : name
    }

}
