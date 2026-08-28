import XCTest
@testable import Corral

final class SessionActivityTests: XCTestCase {

    /// Both tools name a project's folder after its path, and both mappings
    /// were read off a real machine rather than guessed — so these are the
    /// tests that catch it if either scheme changes under us.
    func testCursorNamesAProjectFolderAfterTheMD5OfItsPath() {
        XCTAssertEqual(
            CursorCLISessionActivityReader.directoryName(
                for: "/Volumes/webroot/github/popy_app"
            ),
            "724ef0a2a9e7f330506ab06ab661ee46"
        )
    }

    func testClaudeNamesAProjectFolderAfterThePathItself() {
        XCTAssertEqual(
            ClaudeSessionActivityReader.directoryName(
                for: "/Volumes/webroot/github/popy_app"
            ),
            "-Volumes-webroot-github-popy-app"
        )
    }

    /// The mapping Claude uses is lossy, which is exactly why the reader checks
    /// the path recorded inside the entries rather than trusting the folder.
    func testClaudeFolderNamesCollide() {
        XCTAssertEqual(
            ClaudeSessionActivityReader.directoryName(for: "/a/popy_app"),
            ClaudeSessionActivityReader.directoryName(for: "/a/popy-app")
        )
    }

    /// An entry written after the session cd'd into a subdirectory still
    /// belongs to that session; one from a sibling project does not.
    func testAnEntryBelongsToTheProjectItIsUnder() {
        XCTAssertTrue(ClaudeSessionActivityReader.belongs("/a/b", to: "/a/b"))
        XCTAssertTrue(ClaudeSessionActivityReader.belongs("/a/b/corral", to: "/a/b"))
        XCTAssertFalse(ClaudeSessionActivityReader.belongs("/a/bc", to: "/a/b"))
        XCTAssertFalse(ClaudeSessionActivityReader.belongs("/a", to: "/a/b"))
    }
}
