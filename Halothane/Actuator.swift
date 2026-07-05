import Foundation
import Darwin

/// Sends signals to processes. SIGSTOP cannot be caught, blocked, or ignored,
/// so a paused process is genuinely frozen and cannot allocate further memory.
///
/// We pause the whole process *tree* by default: a runaway leak frequently
/// lives in a helper/child process (e.g. an ACP proxy spawned by the editor),
/// and stopping only the parent would leave the real offender running.
enum Actuator {

    @discardableResult
    static func signal(_ pid: pid_t, _ sig: Int32) -> Bool {
        Darwin.kill(pid, sig) == 0
    }

    /// Freeze a list of pids. Returns the ones successfully stopped.
    @discardableResult
    static func stop(_ pids: [pid_t]) -> [pid_t] {
        pids.filter { signal($0, SIGSTOP) }
    }

    /// Resume a list of pids.
    @discardableResult
    static func resume(_ pids: [pid_t]) -> [pid_t] {
        pids.filter { signal($0, SIGCONT) }
    }

    /// Graceful terminate (SIGTERM). Caller may escalate to kill() if needed.
    @discardableResult
    static func terminate(_ pids: [pid_t]) -> [pid_t] {
        // A stopped process won't act on SIGTERM until resumed, so wake it first.
        for p in pids { signal(p, SIGCONT) }
        return pids.filter { signal($0, SIGTERM) }
    }

    /// Hard kill (SIGKILL) — reclaims the memory immediately.
    @discardableResult
    static func kill(_ pids: [pid_t]) -> [pid_t] {
        pids.filter { signal($0, SIGKILL) }
    }
}
