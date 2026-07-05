import Foundation

/// Shared Mach service name for the privileged daemon's XPC listener. Lives in
/// the system bootstrap namespace (LaunchDaemon), so it's reachable from every
/// GUI session — which is what makes cross-account / fast-user-switch work.
let kHalothaneMachServiceName = "com.sfoln.Halothane.Helper"

/// What the UI talks to. Either an in-process engine (current user) or the
/// root daemon over XPC. The UI is identical against both.
protocol SupervisorBackend: AnyObject {
    var onSnapshot: ((Snapshot) -> Void)? { get set }
    var onEvent: ((SupervisorEvent) -> Void)? { get set }
    func start()
    func updateConfig(_ c: ConfigData)
    func pauseNow(pid: pid_t)
    func resume(pid: pid_t)
    func quit(pid: pid_t)
    func kill(pid: pid_t)
    /// Disarm (pause) or re-arm monitoring. `until == nil` re-arms.
    func setDisarm(until: Date?)
}

/// In-process backend: runs `SupervisorCore` directly. Used as a fallback when
/// the privileged daemon isn't installed/reachable — governs only processes the
/// current user can signal.
final class LocalBackend: SupervisorBackend {
    var onSnapshot: ((Snapshot) -> Void)?
    var onEvent: ((SupervisorEvent) -> Void)?
    private let core: SupervisorCore

    init(config: ConfigData) {
        core = SupervisorCore(config: config, isRoot: false)
        core.onSnapshot = { [weak self] s in self?.onSnapshot?(s) }
        core.onEvent = { [weak self] e in self?.onEvent?(e) }
    }

    func start() { core.start() }
    func updateConfig(_ c: ConfigData) { core.updateConfig(c) }
    func pauseNow(pid: pid_t) { core.pauseNow(pid: pid) }
    func resume(pid: pid_t) { core.resume(pid: pid) }
    func quit(pid: pid_t) { core.quit(pid: pid) }
    func kill(pid: pid_t) { core.kill(pid: pid) }
    func setDisarm(until: Date?) { core.setDisarm(until: until) }
}

// MARK: - XPC contract

/// Calls the UI (client) makes on the daemon. All payloads are JSON `Data` of
/// the Codable model types — avoids NSSecureCoding boilerplate and keeps the
/// wire format identical to local delivery.
@objc protocol DaemonProtocol {
    func subscribe()
    func applyConfig(_ json: Data)
    func pauseNow(_ pid: Int32)
    func resume(_ pid: Int32)
    func quit(_ pid: Int32)
    func kill(_ pid: Int32)
    /// Disarm until the given Unix epoch; `<= 0` re-arms now. `Date.distantFuture`
    /// epoch means "until the user resumes".
    func setDisarm(_ untilEpoch: Double)
}

/// Calls the daemon makes back on each subscribed client.
@objc protocol DaemonClientProtocol {
    func receiveSnapshot(_ json: Data)
    func receiveEvent(_ json: Data)
}
