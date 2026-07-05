import Foundation

/// XPC client backend: connects the UI to the root daemon's Mach service.
/// Because the daemon is a system LaunchDaemon, its service is in the global
/// bootstrap namespace and reachable from any logged-in account.
final class RemoteBackend: NSObject, SupervisorBackend, DaemonClientProtocol {
    var onSnapshot: ((Snapshot) -> Void)?
    var onEvent: ((SupervisorEvent) -> Void)?

    private var connection: NSXPCConnection?
    private var pendingConfig: ConfigData?

    /// Try to reach the daemon. Returns true if a connection object was created
    /// and a probe call dispatched (reachability is confirmed asynchronously via
    /// the first snapshot; `onUnavailable` fires if the connection drops).
    var onUnavailable: (() -> Void)?

    func connect() -> Bool {
        let conn = NSXPCConnection(machServiceName: kHalothaneMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: DaemonProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: DaemonClientProtocol.self)
        conn.exportedObject = self
        conn.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.onUnavailable?() }
        }
        conn.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.onUnavailable?() }
        }
        conn.resume()
        self.connection = conn
        return true
    }

    func disconnect() {
        onSnapshot = nil
        onEvent = nil
        onUnavailable = nil
        connection?.invalidate()
        connection = nil
    }

    private var proxy: DaemonProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async { self?.onUnavailable?() }
        } as? DaemonProtocol
    }

    // MARK: SupervisorBackend

    func start() {
        proxy?.subscribe()
        if let c = pendingConfig { proxy?.applyConfig((try? JSONEncoder().encode(c)) ?? Data()) }
    }

    func updateConfig(_ c: ConfigData) {
        pendingConfig = c
        if let json = try? JSONEncoder().encode(c) { proxy?.applyConfig(json) }
    }

    func pauseNow(pid: pid_t) { proxy?.pauseNow(pid) }
    func resume(pid: pid_t) { proxy?.resume(pid) }
    func quit(pid: pid_t) { proxy?.quit(pid) }
    func kill(pid: pid_t) { proxy?.kill(pid) }
    func setDisarm(until: Date?) { proxy?.setDisarm(until?.timeIntervalSince1970 ?? 0) }

    // MARK: DaemonClientProtocol (daemon -> us)

    func receiveSnapshot(_ json: Data) {
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: json) else { return }
        DispatchQueue.main.async { self.onSnapshot?(snap) }
    }

    func receiveEvent(_ json: Data) {
        guard let ev = try? JSONDecoder().decode(SupervisorEvent.self, from: json) else { return }
        DispatchQueue.main.async { self.onEvent?(ev) }
    }
}
