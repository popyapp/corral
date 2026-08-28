import Foundation

/// Turns a line of Markdown into the text a person would read out loud.
///
/// Agents write their messages in Markdown, so a summary lifted straight out of
/// a transcript arrives as `Release **v2026.08.27-b99** yayında` and the list
/// shows the asterisks. There is room for one line in a row, already truncated,
/// so the aim is plain readable text rather than rendering: syntax removed,
/// every word kept, including the text of links and the contents of code spans.
///
/// It is deliberately conservative. Prose is full of characters that only look
/// like Markdown — `2 * 3`, `popy_app`, `a_b_c` — and a stripper that eats
/// those is worse than one that leaves the occasional asterisk. So a delimiter
/// is only removed when its closing partner is actually there, and `_` is never
/// treated as emphasis on its own: intraword underscores are ordinary
/// characters in file names and identifiers, and far more common here than
/// italics.
enum MarkdownText {

    /// Applied in order. Code spans go first so their delimiters are gone
    /// before emphasis is considered, and links last so their label is left
    /// behind for the earlier rules to have already cleaned.
    private static let inlineRules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // `code` and ``code with a backtick``
            ("`{1,3}([^`]+)`{1,3}", "$1"),
            // ***both***, **bold**, __bold__
            ("\\*\\*\\*([^*]+)\\*\\*\\*", "$1"),
            ("\\*\\*([^*]+)\\*\\*", "$1"),
            ("__([^_]+)__", "$1"),
            // ~~struck through~~
            ("~~([^~]+)~~", "$1"),
            // *italic* — the opening star must be followed by a real character,
            // which is what keeps `2 * 3` and `a * b * c` intact.
            ("\\*(\\S[^*]*?)\\*", "$1"),
            // ![alt](src) before [text](href), or the image's ! is left behind.
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// Leading block syntax: headings, quotes, and bullet or numbered items.
    private static let blockPrefix = try? NSRegularExpression(
        pattern: "^\\s*(?:#{1,6}\\s+|>\\s*|[-*+]\\s+|\\d+[.)]\\s+)+"
    )

    /// The opening or closing line of a code block.
    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// A fence, a horizontal rule, or a table divider — punctuation standing in
    /// for structure, with no words in it worth showing.
    static func isStructural(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if isFence(trimmed) { return true }
        return trimmed.allSatisfy { "-=*_|: ".contains($0) }
    }

    static func plain(_ markdown: String) -> String {
        var text = markdown
        if let blockPrefix {
            text = blockPrefix.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        for (expression, template) in inlineRules {
            text = expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
        // A backslash escape has done its job once the syntax around it is gone.
        text = text.replacingOccurrences(
            of: "\\\\([\\\\`*_{}\\[\\]()#+\\-.!])",
            with: "$1",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespaces)
    }
}
