import XCTest
@testable import Corral

/// End-to-end tests against processes this test actually starts.
///
/// This is how we test Codex and Cursor support without installing either.
/// Recognition keys on the executable's *path*, so a process is "Codex" if it
/// runs from a binary called `codex` — and nothing stops a test from making
/// one. Each test compiles a do-nothing binary under the name it wants and runs
/// it, which exercises the whole chain for real: the kernel process table,
/// `proc_pidpath`, `proc_pidinfo` for the working directory, `rusage`, the
/// catalog, and the grouping.
///
/// A shell script would not do. `proc_pidpath` reports the *interpreter* for a
/// script, so a script named `codex` shows up as `/bin/sh` and proves nothing.
final class LiveProcessTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning {
            process.terminate()
        }
        spawned.removeAll()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Compile a do-nothing binary under the given name.
    ///
    /// Copying `/bin/sleep` and renaming it does not work: macOS checks that an
    /// Apple-signed platform binary is running from its real location and
    /// SIGKILLs the copy (exit 137). The test has to build its own binary, so
    /// it does — three lines of C, once per name.
    private func buildBinary(named name: String) throws -> URL {
        let binary = temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: binary.path) { return binary }

        let source = temporaryDirectory.appendingPathComponent("\(name).c")
        try "#include <unistd.h>\nint main(void){ sleep(120); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-o", binary.path, source.path]
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw XCTSkip("cc is unavailable, so the live-process tests cannot build a fixture")
        }
        return binary
    }

    /// Start a long-lived process whose executable is named `name` and whose
    /// working directory is `workingDirectory`.
    @discardableResult
    private func spawn(
        named name: String,
        workingDirectory: URL
    ) throws -> (process: Process, path: URL) {
        let binary = try buildBinary(named: name)

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)

        // The process table is not updated synchronously with run().
        try waitUntil("process \(process.processIdentifier) is visible") {
            ProcessScanner.scan().contains { $0.pid == process.processIdentifier }
        }
        return (process, binary)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting until \(description)")
    }

    private func find(pid: pid_t) -> ProcessScanner.Raw? {
        ProcessScanner.scan().first { $0.pid == pid }
    }

    // ─ Codex ────────────────────────────────────────────────────────────────

    func testCodexProcessIsDetectedWithItsProject() throws {
        let project = temporaryDirectory.appendingPathComponent("my-api-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let (process, binary) = try spawn(named: "codex", workingDirectory: project)
        let raw = try XCTUnwrap(find(pid: process.processIdentifier))

        // proc_pidpath resolves symlinks, and /var is a link to /private/var,
        // so compare resolved paths rather than the strings we started with.
        XCTAssertEqual(
            raw.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            binary.resolvingSymlinksInPath().path
        )

        let match = try XCTUnwrap(
            ToolCatalog.identify(raw), "a binary named codex should be recognised as Codex"
        )
        XCTAssertEqual(match.tool, .codex)
        XCTAssertEqual(match.role, .agent)

        // The whole premise of the app: the process knows which project it is in.
        let cwd = try XCTUnwrap(raw.workingDirectory)
        XCTAssertEqual(
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
            project.resolvingSymlinksInPath().path
        )
    }

    /// Find a spawned process in the inventory — as a group root, or as a child.
    ///
    /// Which of the two it turns out to be depends on where the suite itself is
    /// running. Launch the tests from inside an agent's shell, an increasingly
    /// ordinary thing to do, and the process we just spawned is that agent's
    /// descendant, so AgentInventory lists it under that agent's group instead
    /// of giving it one of its own. That is deliberate — an agent you started
    /// from another agent's shell keeps its identity but stays in the tree it
    /// belongs to — so asserting on `groups.first { $0.root.pid == pid }` was
    /// testing the terminal the suite happened to run in, not the inventory.
    private func locate(
        pid: pid_t, in inventory: AgentInventory
    ) -> (group: AgentGroup, process: AgentProcess)? {
        for group in inventory.groups {
            if let hit = group.all.first(where: { $0.pid == pid }) { return (group, hit) }
        }
        return nil
    }

    func testCodexAppearsInTheInventoryUnderItsProjectName() throws {
        let project = temporaryDirectory.appendingPathComponent("checkout-service")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let (process, _) = try spawn(named: "codex", workingDirectory: project)

        let inventory = AgentInventory()
        inventory.refresh()

        let found = try XCTUnwrap(
            locate(pid: process.processIdentifier, in: inventory),
            "Codex should show up in the inventory"
        )
        XCTAssertEqual(found.process.tool, .codex)
        XCTAssertEqual(found.process.projectName, "checkout-service")
    }

    // ─ Cursor ───────────────────────────────────────────────────────────────

    func testCursorAgentProcessIsDetected() throws {
        let project = temporaryDirectory.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let (process, _) = try spawn(named: "cursor-agent", workingDirectory: project)

        let raw = try XCTUnwrap(find(pid: process.processIdentifier))
        let match = try XCTUnwrap(ToolCatalog.identify(raw))
        XCTAssertEqual(match.tool, .cursorAgent)
        XCTAssertEqual(raw.workingDirectory.map { ($0 as NSString).lastPathComponent }, "frontend")
    }

    // ─ Rejection, for real ──────────────────────────────────────────────────

    func testAnUnrelatedProcessIsNotClaimedByAnyTool() throws {
        let (process, _) = try spawn(named: "totally-unrelated", workingDirectory: temporaryDirectory)
        let raw = try XCTUnwrap(find(pid: process.processIdentifier))
        XCTAssertNil(ToolCatalog.identify(raw))
    }

    // ─ Stopping ─────────────────────────────────────────────────────────────

    func testStoppingAnAgentActuallyEndsIt() throws {
        let project = temporaryDirectory.appendingPathComponent("doomed")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let (process, _) = try spawn(named: "codex", workingDirectory: project)
        let pid = process.processIdentifier

        let inventory = AgentInventory()
        inventory.refresh()
        let found = try XCTUnwrap(locate(pid: pid, in: inventory))

        // Stop exactly what this test spawned, and nothing else. When the suite
        // runs inside an agent's shell the spawned process is listed under that
        // agent's group, and handing that whole group to Terminator would take
        // the agent running the tests down with it.
        let group = AgentGroup(root: found.process, children: [])
        let outcome = Terminator.stop(group, method: .graceful, gracePeriod: 3)
        XCTAssertTrue(outcome.stopped.contains(pid), "the agent should have stopped")
        XCTAssertTrue(outcome.survived.isEmpty)
        XCTAssertTrue(outcome.refused.isEmpty)

        try waitUntil("the process is gone") { !ProcessScanner.isAlive(pid) }
    }

    func testTerminatorRefusesLaunchdAndItself() {
        let launchd = AgentProcess(
            pid: 1, ppid: 0, tool: .codex, role: .agent, comm: "launchd",
            executablePath: "/sbin/launchd", arguments: [], workingDirectory: "/",
            residentBytes: 0, cpuSeconds: 0, startedAt: Date(), version: nil,
            tty: nil, lastTerminalActivity: nil
        )
        let outcome = Terminator.stop([launchd], method: .force)
        XCTAssertEqual(outcome.refused, [1])
        XCTAssertTrue(outcome.stopped.isEmpty)
        XCTAssertTrue(ProcessScanner.isAlive(1), "launchd is obviously still running")
    }

    // ─ Scanner sanity ───────────────────────────────────────────────────────

    func testScannerReadsTheFactsItPromises() throws {
        let raw = try XCTUnwrap(find(pid: getpid()), "we should be able to see ourselves")
        XCTAssertNotNil(raw.executablePath)
        XCTAssertFalse(raw.arguments.isEmpty, "argv should be readable")
        XCTAssertNotNil(raw.workingDirectory, "cwd is the fact the whole app rests on")
        XCTAssertGreaterThan(raw.residentBytes, 0)
        XCTAssertLessThan(raw.startedAt, Date())
    }

    /// The two scans must date a process identically.
    ///
    /// They arrive by different routes: the lightweight pass reads
    /// `p_starttime` straight out of the kernel table, the full scan builds a
    /// `Date` for the row. Any drift between them means the full scan has gone
    /// back to *deriving* the answer from a clock instead of reading it, which
    /// is not a hypothetical failure — it derived it from `mach_absolute_time`,
    /// which stops while the Mac is asleep, and every agent came out younger
    /// than it was by however long the machine had slept. Agents launched five
    /// days earlier were dated to two days ago.
    ///
    /// That is worth a test of its own because of what it broke downstream. A
    /// process's start time is what rules out session logs older than the
    /// process that would be reading them, so a slow clock did not show up as a
    /// wrong date — it showed up as one agent's transcript being read out under
    /// another agent's name.
    func testBothScansDateAProcessIdentically() {
        let fromKernel = Dictionary(
            ProcessScanner.scanLightweight().map { ($0.pid, $0.startTime) },
            uniquingKeysWith: { first, _ in first }
        )

        var compared = 0
        for raw in ProcessScanner.scan() {
            guard let expected = fromKernel[raw.pid] else { continue }
            XCTAssertEqual(
                raw.startedAt.timeIntervalSince1970,
                Double(expected),
                accuracy: 1,
                "pid \(raw.pid) (\(raw.comm)) is dated differently by the two scans"
            )
            compared += 1
        }
        XCTAssertGreaterThan(compared, 0, "no process was visible to both scans")
    }
}
