import Foundation
import Darwin

/// Thin wrappers over libproc to read per-process memory + identity.
///
/// `phys_footprint` (RUSAGE_INFO_V6) is the same metric Activity Monitor shows
/// in its "Memory" column — it accounts for compressed and dirty pages, unlike
/// raw RSS. For processes owned by other users, `proc_pid_rusage` requires
/// elevated privileges; in Phase 1 (in-process, current user) we simply skip
/// the ones we can't read. Phase 2 moves this into the root daemon so every
/// process across both accounts is visible.
enum ProcInfo {

    /// All PIDs on the system.
    static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, needed)
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// phys_footprint in bytes, or nil if unreadable (permission / gone).
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// (ppid, uid) via the BSD short info record, in one syscall.
    static func parentAndOwner(_ pid: pid_t) -> (ppid: pid_t, uid: uid_t)? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return (pid_t(info.pbsi_ppid), uid_t(info.pbsi_uid))
    }

    /// Best-effort process name.
    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let rc = proc_name(pid, &buf, UInt32(buf.count))
        if rc > 0 {
            let s = String(cString: buf)
            if !s.isEmpty { return s }
        }
        if let p = path(pid) { return (p as NSString).lastPathComponent }
        return "pid \(pid)"
    }

    /// Full executable path, if readable.
    static func path(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE == 4 * MAXPATHLEN (4 * 1024); the macro isn't
        // always surfaced to Swift, so use the literal.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        let rc = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard rc > 0 else { return nil }
        return String(cString: buf)
    }

    /// Sample every process at or above `floor` bytes of footprint.
    /// Returns a parent map alongside so callers can build process trees.
    static func sample(floor: UInt64, now: Date) -> (samples: [ProcSample], childrenOf: [pid_t: [pid_t]]) {
        var samples: [ProcSample] = []
        var children: [pid_t: [pid_t]] = [:]

        for pid in allPIDs() {
            guard let owner = parentAndOwner(pid) else { continue }
            children[owner.ppid, default: []].append(pid)

            guard let fp = footprint(pid) else { continue }
            if fp < floor { continue }
            samples.append(
                ProcSample(
                    pid: pid,
                    ppid: owner.ppid,
                    uid: owner.uid,
                    name: name(pid),
                    path: path(pid),
                    footprint: fp,
                    growthRate: nil,
                    timestamp: now
                )
            )
        }
        return (samples, children)
    }

    /// Processes visible to the current user, as (name, path) candidates for
    /// autocomplete. The name is the raw proc_name (what rules match on); the
    /// path is carried for searching and as an identifying hint. (The daemon's
    /// snapshot covers large system-wide processes; this fills in the rest.)
    static func currentUserProcesses() -> [ProcCandidate] {
        var byName: [String: String?] = [:]
        for pid in allPIDs() {
            let n = name(pid)
            guard !n.isEmpty, !n.hasPrefix("pid ") else { continue }
            if byName[n] == nil { byName[n] = path(pid) }
        }
        return byName.map { ProcCandidate(name: $0.key, path: $0.value) }
    }

    /// Depth-first collection of a process and all its descendants.
    static func tree(of pid: pid_t, childrenOf: [pid_t: [pid_t]]) -> [pid_t] {
        var result: [pid_t] = []
        var stack: [pid_t] = [pid]
        while let p = stack.popLast() {
            result.append(p)
            if let kids = childrenOf[p] { stack.append(contentsOf: kids) }
        }
        return result
    }
}
