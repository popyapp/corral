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

    func testCodexAppearsInTheInventoryUnderItsProjectName() throws {
        let project = temporaryDirectory.appendingPathComponent("checkout-service")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let (process, _) = try spawn(named: "codex", workingDirectory: project)

        let inventory = AgentInventory()
        inventory.refresh()

        let group = try XCTUnwrap(
            inventory.groups.first { $0.root.pid == process.processIdentifier },
            "Codex should show up as an agent in the inventory"
        )
        XCTAssertEqual(group.root.tool, .codex)
        XCTAssertEqual(group.root.projectName, "checkout-service")
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
        let group = try XCTUnwrap(inventory.groups.first { $0.root.pid == pid })

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
}
