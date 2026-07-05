import Foundation

/// Headless root-daemon mode (`Halothane --daemon`, launched by launchd). Runs
/// the supervision engine system-wide and serves the XPC Mach service that the
/// per-user UI(s) connect to. Persists the authoritative config under
/// /Library/Application Support/Halothane.
final class DaemonMain: NSObject, NSXPCListenerDelegate, DaemonProtocol {

    private static let configPath = "/Library/Application Support/Halothane/config.json"

    private let core: SupervisorCore
    private let listener: NSXPCListener
    /// Connected UI clients to broadcast snapshots/events to.
    private var clients: [NSXPCConnection] = []
    private let lock = NSLock()
    /// Most recent snapshot, sent immediately to each client on subscribe so
    /// the UI populates instantly instead of waiting for the next tick.
    private var lastSnapshotJSON: Data?

    static func run() -> Never {
        let daemon = DaemonMain()
        daemon.listener.resume()
        daemon.core.start()
        NSLog("Halothane daemon: started, serving \(kHalothaneMachServiceName)")
        // Block forever servicing XPC + timers.
        dispatchMain()
    }

    override init() {
        let cfg = DaemonMain.loadConfig() ?? .default
        core = SupervisorCore(config: cfg, isRoot: true)
        listener = NSXPCListener(machServiceName: kHalothaneMachServiceName)
        super.init()
        listener.delegate = self
        core.onSnapshot = { [weak self] snap in self?.broadcast(snapshot: snap) }
        core.onEvent = { [weak self] ev in self?.broadcast(event: ev) }
    }

    // MARK: - XPC listener

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard ClientTrust.isAuthorized(conn) else {
            NSLog("Halothane daemon: rejected connection from pid \(conn.processIdentifier)")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: DaemonProtocol.self)
        conn.exportedObject = self
        conn.remoteObjectInterface = NSXPCInterface(with: DaemonClientProtocol.self)
        conn.invalidationHandler = { [weak self, weak conn] in self?.remove(conn) }
        conn.interruptionHandler = { [weak self, weak conn] in self?.remove(conn) }
        conn.resume()
        lock.lock(); clients.append(conn); lock.unlock()
        return true
    }

    private func remove(_ conn: NSXPCConnection?) {
        guard let conn else { return }
        lock.lock(); clients.removeAll { $0 === conn }; lock.unlock()
    }

    private func broadcast(snapshot: Snapshot) {
        guard let json = try? JSONEncoder().encode(snapshot) else { return }
        lock.lock(); lastSnapshotJSON = json; lock.unlock()
        forEachClient { ($0.remoteObjectProxy as? DaemonClientProtocol)?.receiveSnapshot(json) }
    }

    private func broadcast(event: SupervisorEvent) {
        guard let json = try? JSONEncoder().encode(event) else { return }
        forEachClient { ($0.remoteObjectProxy as? DaemonClientProtocol)?.receiveEvent(json) }
    }

    private func forEachClient(_ body: (NSXPCConnection) -> Void) {
        lock.lock(); let snapshot = clients; lock.unlock()
        snapshot.forEach(body)
    }

    // MARK: - DaemonProtocol (client -> us)

    func subscribe() {
        // Push the latest snapshot to the just-subscribed client immediately.
        lock.lock(); let json = lastSnapshotJSON; lock.unlock()
        if let json, let conn = NSXPCConnection.current() {
            (conn.remoteObjectProxy as? DaemonClientProtocol)?.receiveSnapshot(json)
        }
    }

    func applyConfig(_ json: Data) {
        guard let cfg = try? JSONDecoder().decode(ConfigData.self, from: json) else { return }
        core.updateConfig(cfg)
        DaemonMain.saveConfig(cfg)
    }

    func pauseNow(_ pid: Int32) { core.pauseNow(pid: pid) }
    func resume(_ pid: Int32) { core.resume(pid: pid) }
    func quit(_ pid: Int32) { core.quit(pid: pid) }
    func kill(_ pid: Int32) { core.kill(pid: pid) }
    func setDisarm(_ untilEpoch: Double) {
        core.setDisarm(until: untilEpoch <= 0 ? nil : Date(timeIntervalSince1970: untilEpoch))
    }

    // MARK: - Config persistence (root-owned, shared across accounts)

    private static func loadConfig() -> ConfigData? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONDecoder().decode(ConfigData.self, from: data)
    }

    private static func saveConfig(_ c: ConfigData) {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }
}
