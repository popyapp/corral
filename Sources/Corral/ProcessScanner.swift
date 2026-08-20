import Darwin
import Foundation

/// Raw process facts, read straight from the kernel.
///
/// Everything here works for the current user's own processes with no root and
/// no entitlements: `sysctl` for the table and the argument vector,
/// `proc_pidinfo` for the working directory, `proc_pid_rusage` for memory and
/// CPU. We never shell out to `ps` — it can't give us the working directory,
/// which is the one fact that makes this app worth having.
enum ProcessScanner {

    struct Raw {
        let pid: pid_t
        let ppid: pid_t
        let comm: String
        let executablePath: String?
        let arguments: [String]
        let workingDirectory: String?
        let residentBytes: UInt64
        let cpuSeconds: Double
        let startedAt: Date
        let tty: String?
        let lastTerminalActivity: Date?
    }

    /// Every process owned by the current user.
    static func scan() -> [Raw] {
        let uid = getuid()
        return kernelProcessTable()
            .filter { $0.kp_proc.p_pid > 0 && $0.kp_eproc.e_ucred.cr_uid == uid }
            .compactMap { kp in
                let pid = kp.kp_proc.p_pid
                // A process can exit between the table read and these lookups;
                // rusage is the one we can't do without, so it gates the row.
                guard let usage = usage(of: pid) else { return nil }
                let tty = terminal(of: kp)
                return Raw(
                    pid: pid,
                    ppid: kp.kp_eproc.e_ppid,
                    comm: comm(of: kp),
                    executablePath: executablePath(of: pid),
                    arguments: arguments(of: pid) ?? [],
                    workingDirectory: workingDirectory(of: pid),
                    residentBytes: usage.resident,
                    cpuSeconds: usage.cpuSeconds,
                    startedAt: usage.startedAt,
                    tty: tty,
                    lastTerminalActivity: tty.flatMap(lastWrite(toTerminal:))
                )
            }
    }

    // ─ Kernel process table ─────────────────────────────────────────────────

    private static func kernelProcessTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Processes can appear between sizing and reading, so ask for headroom
        // and trust the size the second call reports back.
        let slack = 32
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(),
            count: size / MemoryLayout<kinfo_proc>.stride + slack
        )
        size = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func comm(of kp: kinfo_proc) -> String {
        withUnsafePointer(to: kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
    }

    // ─ Executable path ──────────────────────────────────────────────────────

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return written > 0 ? String(cString: buffer) : nil
    }

    // ─ Argument vector ──────────────────────────────────────────────────────

    /// `KERN_PROCARGS2` returns, in order: `argc` as an Int32, the executable
    /// path, NUL padding, then `argc` NUL-terminated arguments, then the
    /// environment. We stop at `argc` so the environment — which holds tokens
    /// and API keys — is never read into memory we then display.
    static func arguments(of pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        size = Int(argmax)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding

        var args: [String] = []
        var current: [CChar] = []
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                current.append(0)
                args.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return args
    }

    // ─ Working directory ────────────────────────────────────────────────────

    /// The process's cwd. This is what turns an anonymous `2.1.235` into
    /// "the agent you left running in ~/code/api".
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let written = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard written == Int32(size) else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }

    // ─ Controlling terminal ─────────────────────────────────────────────────

    /// The controlling terminal, as a device path. `e_tdev` is a raw `dev_t`;
    /// `devname` is the libc call that turns one back into `ttys004`.
    static func terminal(of kp: kinfo_proc) -> String? {
        let dev = kp.kp_eproc.e_tdev
        // NODEV (-1) means no controlling terminal — a GUI app, or a daemon.
        guard dev != -1, dev != 0 else { return nil }
        guard let name = devname(dev, S_IFCHR) else { return nil }
        let base = String(cString: name)
        return base.isEmpty ? nil : "/dev/" + base
    }

    /// When the terminal was last written to.
    ///
    /// This is the one activity signal that predates Corral: the kernel has
    /// been stamping it all along, so an agent abandoned three days ago reads
    /// as three days idle the very first time we look, instead of "idle 1s"
    /// because that is how long we have been watching.
    static func lastWrite(toTerminal path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let m = st.st_mtimespec
        let interval = Double(m.tv_sec) + Double(m.tv_nsec) / 1e9
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    // ─ Memory and CPU ───────────────────────────────────────────────────────

    struct Usage {
        let resident: UInt64
        let cpuSeconds: Double
        let startedAt: Date
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }

        // ri_proc_start_abstime shares a clock with mach_absolute_time(), so
        // the difference is wall-clock age — and unlike a stored boot-relative
        // timestamp it survives the machine sleeping.
        let now = mach_absolute_time()
        let ageNanos = now > info.ri_proc_start_abstime
            ? Double(now - info.ri_proc_start_abstime) * timebase
            : 0
        let cpuNanos = Double(info.ri_user_time &+ info.ri_system_time)

        return Usage(
            resident: info.ri_resident_size,
            cpuSeconds: cpuNanos / 1e9,
            startedAt: Date(timeIntervalSinceNow: -ageNanos / 1e9)
        )
    }

    /// Whether a pid is still alive — `kill(pid, 0)` signals nothing, it only
    /// checks that we could.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
