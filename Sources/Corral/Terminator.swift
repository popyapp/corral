import Darwin
import Foundation

/// Stopping agents.
///
/// The blog posts that make people install an app like this all end the same
/// way: `pkill -9 -f cursor`. That works, and it also throws away whatever the
/// agent had in flight and orphans its children. Corral does the polite thing
/// first and the brutal thing only when asked, and it always tells you what it
/// actually managed to stop.
enum Terminator {

    enum Method {
        /// SIGTERM — the agent gets to flush state and exit cleanly.
        case graceful
        /// SIGKILL — immediate, unblockable, no cleanup.
        case force

        var signal: Int32 { self == .graceful ? SIGTERM : SIGKILL }
    }

    struct Outcome {
        let stopped: [pid_t]
        let survived: [pid_t]
        let refused: [pid_t]
        let reclaimedBytes: UInt64

        var isCompleteSuccess: Bool { survived.isEmpty && refused.isEmpty }
    }

    /// Stop a whole group: children first, then the agent.
    ///
    /// Children first is not cosmetic. Kill the agent and its MCP servers are
    /// reparented to launchd, where they sit forever with no one to talk to —
    /// which is precisely the mess this app exists to clean up.
    static func stop(
        _ group: AgentGroup,
        method: Method,
        gracePeriod: TimeInterval = 2.0
    ) -> Outcome {
        let ordered = group.children.reversed() + [group.root]
        return stop(Array(ordered), method: method, gracePeriod: gracePeriod)
    }

    static func stop(
        _ processes: [AgentProcess],
        method: Method,
        gracePeriod: TimeInterval = 2.0
    ) -> Outcome {
        var stopped: [pid_t] = []
        var refused: [pid_t] = []
        var signalled: [pid_t] = []
        var bytes: UInt64 = 0

        for process in processes {
            guard isOurs(process.pid) else {
                // Never signal something that is not ours to signal. The scan
                // is already uid-filtered, but a pid can be recycled between
                // the scan and the click.
                refused.append(process.pid)
                continue
            }
            if kill(process.pid, method.signal) == 0 {
                signalled.append(process.pid)
                bytes += process.residentBytes
            } else if errno == ESRCH {
                // Already gone — that is the outcome we wanted.
                stopped.append(process.pid)
                bytes += process.residentBytes
            } else {
                refused.append(process.pid)
            }
        }

        // SIGTERM is a request. Give it a moment, then report honestly on who
        // ignored it rather than pretending the click worked.
        if method == .graceful, !signalled.isEmpty {
            let deadline = Date().addingTimeInterval(gracePeriod)
            while Date() < deadline {
                if signalled.allSatisfy({ !ProcessScanner.isAlive($0) }) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        var survived: [pid_t] = []
        for pid in signalled {
            if ProcessScanner.isAlive(pid) {
                survived.append(pid)
                bytes -= min(bytes, residentOf(pid))
            } else {
                stopped.append(pid)
            }
        }

        return Outcome(
            stopped: stopped,
            survived: survived,
            refused: refused,
            reclaimedBytes: bytes
        )
    }

    /// True when the pid exists and belongs to us.
    private static func isOurs(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }               // never launchd
        guard pid != getpid() else { return false }        // never ourselves
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid()
    }

    private static func residentOf(_ pid: pid_t) -> UInt64 {
        ProcessScanner.usage(of: pid)?.resident ?? 0
    }
}
