import Foundation

/// The supervision engine, with no UI or actor dependencies. It samples on a
/// dispatch timer, applies policy, drives the actuator, tracks paused state,
/// and emits a `Snapshot` each tick plus discrete `SupervisorEvent`s. The exact
/// same class runs in-process (current user) and inside the root daemon
/// (system-wide). All mutable state lives on `queue`.
final class SupervisorCore {
    /// Called every tick with the full UI state. Delivered on `queue`.
    var onSnapshot: ((Snapshot) -> Void)?
    /// Called for notable events (warn/pause/...). Delivered on `queue`.
    var onEvent: ((SupervisorEvent) -> Void)?

    private let queue = DispatchQueue(label: "com.sfoln.Halothane.core")
    private let isRoot: Bool

    private var config: ConfigData
    private let growth = GrowthTracker()
    private let pressure = MemoryPressureMonitor()
    private var timer: DispatchSourceTimer?

    private var paused: [PausedProcess] = []
    private var log: [LogEntry] = []
    private var lastWarned: [pid_t: Date] = [:]
    private var status: Severity = .normal
    private var top: [ProcSample] = []
    private var all: [ProcSample] = []
    /// When set, monitoring is "disarmed": the engine keeps sampling for display
    /// but issues no warnings/pauses and ignores memory pressure. It re-arms
    /// automatically once `Date()` passes this (or `Date.distantFuture` = never,
    /// until the user resumes). `nil` = armed/active.
    private var disarmedUntil: Date?

    private let listFloor: UInt64 = 50 * 1_048_576    // 50 MB
    private let allCap = 120                            // cap detail-list payload
    private let warnCooldown: TimeInterval = 120

    init(config: ConfigData, isRoot: Bool) {
        self.config = config
        self.isRoot = isRoot
        pressure.onChange = { [weak self] level in
            self?.queue.async { self?.handlePressure(level) }
        }
        pressure.start(queue: queue)
    }

    // MARK: - Control (thread-safe entry points)

    func start() { queue.async { self.scheduleTimer(); self.tick() } }

    func updateConfig(_ c: ConfigData) {
        queue.async {
            let intervalChanged = c.pollIntervalSeconds != self.config.pollIntervalSeconds
            self.config = c
            if intervalChanged { self.scheduleTimer() }
        }
    }

    /// Pause ("disarm") or resume monitoring. `until == nil` re-arms now;
    /// otherwise the engine stays disarmed until that time (use
    /// `Date.distantFuture` for indefinitely). Affects every account, since this
    /// is the one shared engine.
    func setDisarm(until: Date?) {
        queue.async {
            self.disarmedUntil = until
            self.append(until == nil ? "▶️ Monitoring resumed." : "⏸ Monitoring paused.")
            self.tick()   // refresh UI state immediately
        }
    }

    /// Manually pause a process (and its tree) regardless of thresholds.
    func pauseNow(pid: pid_t) {
        queue.async {
            guard !self.paused.contains(where: { $0.pid == pid }) else { return }
            let (samples, childrenOf) = ProcInfo.sample(floor: 0, now: Date())
            guard let s = samples.first(where: { $0.pid == pid }) else { return }
            self.doPause(s, reason: .manual, childrenOf: childrenOf)
            self.publish()
        }
    }

    func resume(pid: pid_t) { queue.async { self.act(pid) { p in
        Actuator.resume([p.pid] + p.pausedTree)
        self.emit(.resumed, "Resumed \(p.name).", pid: p.pid)
    } } }

    func quit(pid: pid_t) { queue.async { self.act(pid) { p in
        Actuator.terminate([p.pid] + p.pausedTree)
        self.emit(.info, "Asked \(p.name) to quit.", pid: p.pid)
    } } }

    func kill(pid: pid_t) { queue.async { self.act(pid) { p in
        Actuator.kill([p.pid] + p.pausedTree)
        self.emit(.killed, "Force-killed \(p.name).", pid: p.pid)
    } } }

    private func act(_ pid: pid_t, _ body: (PausedProcess) -> Void) {
        guard let p = paused.first(where: { $0.pid == pid }) else { return }
        body(p)
        paused.removeAll { $0.pid == pid }
        lastWarned[pid] = nil
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1, config.pollIntervalSeconds)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - Core loop

    private func tick() {
        let now = Date()
        let (rawSamples, childrenOf) = ProcInfo.sample(floor: listFloor, now: now)

        var samples = rawSamples
        for i in samples.indices {
            samples[i].growthRate = growth.record(pid: samples[i].pid, bytes: samples[i].footprint, now: now)
        }
        let live = Set(samples.map(\.pid))
        growth.prune(livePIDs: live)
        paused.removeAll { !live.contains($0.pid) && ProcInfo.footprint($0.pid) == nil }

        // Auto-re-arm once the disarm window elapses.
        if let until = disarmedUntil, now >= until {
            disarmedUntil = nil
            append("▶️ Monitoring resumed (timer elapsed).")
        }
        let armed = disarmedUntil == nil

        var worst: Severity = .normal
        let pausedPIDs = Set(paused.map(\.pid))

        if armed {
            for s in samples where !pausedPIDs.contains(s.pid) {
                let decision = PolicyEngine.evaluate(s, config: config)
                worst = max(worst, decision.severity)
                switch decision.severity {
                case .normal: break
                case .warn:   maybeWarn(s, reason: decision.reason, now: now)
                case .pause:  doPause(s, reason: decision.reason, childrenOf: childrenOf)
                }
            }
        }

        status = paused.isEmpty ? worst : .pause
        let sorted = samples.sorted { $0.footprint > $1.footprint }
        top = Array(sorted.prefix(8))
        all = Array(sorted.prefix(allCap))
        publish()
    }

    // MARK: - Actions

    private func maybeWarn(_ s: ProcSample, reason: DecisionReason, now: Date) {
        if let last = lastWarned[s.pid], now.timeIntervalSince(last) < warnCooldown { return }
        lastWarned[s.pid] = now
        let detail: String
        if let mb = s.growthMBPerMin, reason == .growthWarn {
            detail = String(format: "%@ — %.1f GB and growing %.0f MB/min", s.name, s.footprintGB, mb)
        } else {
            detail = String(format: "%@ is using %.1f GB (%@)", s.name, s.footprintGB, reason.label)
        }
        append("⚠️ " + detail)
        emit(.warn, detail, pid: s.pid, title: "High memory")
    }

    private func doPause(_ s: ProcSample, reason: DecisionReason, childrenOf: [pid_t: [pid_t]]) {
        let useTree = config.effectivePauseTree(rule: config.rule(for: s.name))
        let pids = useTree ? ProcInfo.tree(of: s.pid, childrenOf: childrenOf) : [s.pid]
        let stopped = Actuator.stop(pids)
        guard !stopped.isEmpty else {
            append("Failed to pause \(s.name) (pid \(s.pid)) — insufficient privilege?")
            return
        }
        paused.append(PausedProcess(
            pid: s.pid, name: s.name, footprintAtPause: s.footprint,
            reason: reason, pausedAt: Date(), pausedTree: stopped.filter { $0 != s.pid }
        ))
        let msg = String(format: "⏸ Paused %@ at %.1f GB (%@)", s.name, s.footprintGB, reason.label)
        append(msg)
        emit(.paused, msg + ". Resume or quit it from the Halothane menu.", pid: s.pid, title: "Process paused")
    }

    private func handlePressure(_ level: MemoryPressureMonitor.Level) {
        guard disarmedUntil == nil else { publish(); return }   // disarmed: don't act
        guard level == .critical, config.pressureCouplingEnabled else { publish(); return }
        let pausedPIDs = Set(paused.map(\.pid))
        let candidate = top.first { s in
            !pausedPIDs.contains(s.pid) && !config.isWhitelisted(s.name) && config.rule(for: s.name)?.exempt != true
        }
        if let s = candidate {
            let (_, childrenOf) = ProcInfo.sample(floor: listFloor, now: Date())
            append("🔴 System memory critical — pausing largest process.")
            doPause(s, reason: .systemPressure, childrenOf: childrenOf)
        }
        publish()
    }

    // MARK: - Output

    private func emit(_ kind: SupervisorEvent.Kind, _ body: String, pid: pid_t, title: String = "Halothane") {
        onEvent?(SupervisorEvent(kind: kind, title: title, body: body, pid: pid))
    }

    private func append(_ message: String) {
        log.insert(LogEntry(time: Date(), message: message), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    private func publish() {
        let snap = Snapshot(
            top: top, all: all, paused: paused, pressure: pressure.level.rawValue,
            status: status, log: log, backendIsRoot: isRoot, disarmedUntil: disarmedUntil
        )
        onSnapshot?(snap)
    }
}
