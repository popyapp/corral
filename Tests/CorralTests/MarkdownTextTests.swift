import XCTest
@testable import Corral

/// The messages here are real ones, lifted out of live transcripts while this
/// was being written.
final class MarkdownTextTests: XCTestCase {

    private func plain(_ s: String) -> String { MarkdownText.plain(s) }

    // ─ Syntax that should go ────────────────────────────────────────────────

    func testBoldAndCodeAreTakenOff() {
        XCTAssertEqual(
            plain("Release tamamlandı: **v2026.08.27-b99** yayında"),
            "Release tamamlandı: v2026.08.27-b99 yayında"
        )
        XCTAssertEqual(
            plain("Push edildi ✅ `b6f7b92..8fbb1a2`. Build temiz."),
            "Push edildi ✅ b6f7b92..8fbb1a2. Build temiz."
        )
    }

    func testHeadingsQuotesAndBulletsLoseTheirMarker() {
        XCTAssertEqual(plain("## Cevabım: evet"), "Cevabım: evet")
        XCTAssertEqual(plain("- Names every agent by its project"), "Names every agent by its project")
        XCTAssertEqual(plain("1. Kesin kimlik"), "Kesin kimlik")
        XCTAssertEqual(plain("> alıntı"), "alıntı")
    }

    func testLinksKeepTheirWordsAndLoseTheirAddress() {
        XCTAssertEqual(
            plain("See [the release](https://example.com/a_b) for details"),
            "See the release for details"
        )
        XCTAssertEqual(plain("![icon](Assets/icon.svg) hazır"), "icon hazır")
    }

    func testItalicAndStrikethrough() {
        XCTAssertEqual(plain("bu *gerçekten* önemli"), "bu gerçekten önemli")
        XCTAssertEqual(plain("~~vazgeçildi~~ tamam"), "vazgeçildi tamam")
    }

    // ─ Prose that only looks like syntax ────────────────────────────────────

    /// The reason `_` is left alone. File names and identifiers are everywhere
    /// in these messages and italics are rare; eating them would be a much
    /// worse bug than leaving an underscore on screen.
    func testUnderscoresInNamesSurvive() {
        XCTAssertEqual(plain("Read move_agent_to_root.json"), "Read move_agent_to_root.json")
        XCTAssertEqual(plain("lib/shots/paths.ts ve use_shot_upload"), "lib/shots/paths.ts ve use_shot_upload")
    }

    func testLoneAsterisksAreNotEmphasis() {
        XCTAssertEqual(plain("2 * 3 = 6"), "2 * 3 = 6")
        XCTAssertEqual(plain("select * from projects"), "select * from projects")
    }

    func testAnUnclosedDelimiterIsLeftAlone() {
        XCTAssertEqual(plain("**yarım kalmış"), "**yarım kalmış")
        XCTAssertEqual(plain("bir `kod parçası"), "bir `kod parçası")
    }

    // ─ Structure with no words in it ────────────────────────────────────────

    func testStructuralLinesAreRecognised() {
        XCTAssertTrue(MarkdownText.isStructural("```swift"))
        XCTAssertTrue(MarkdownText.isStructural("---"))
        XCTAssertTrue(MarkdownText.isStructural("| --- | --- |"))
        XCTAssertTrue(MarkdownText.isStructural("   "))
        XCTAssertFalse(MarkdownText.isStructural("## Ne yapıldı"))
    }

    // ─ What the list actually shows ─────────────────────────────────────────

    func testTheSummarySkipsToTheFirstLineWithWordsInIt() {
        let reply = """
            ```
            some code
            ```
            ## Sonuç
            Her şey **tamam**.
            """
        XCTAssertEqual(SessionActivity.firstLine(reply), "Sonuç")
    }

    /// Stripping happens before the cap, so a message is never cut in the
    /// middle of a delimiter and left showing half of one.
    func testTruncationHappensAfterTheSyntaxIsGone() {
        let long = "**" + String(repeating: "a", count: 200) + "**"
        let line = try? XCTUnwrap(SessionActivity.firstLine(long, limit: 20))
        XCTAssertEqual(line, String(repeating: "a", count: 19) + "…")
    }
}
