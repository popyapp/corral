import SwiftUI

/// One place for colour and type, so the window reads as a designed thing
/// rather than a stack of default controls.
enum Theme {

    // ─ Tool identity ────────────────────────────────────────────────────────

    /// Each product gets a colour, so a wall of rows is scannable before you
    /// have read a single word.
    static func accent(for tool: Tool) -> Color {
        switch tool {
        case .claudeCode, .claudeDesktop:
            return Color(red: 0.85, green: 0.47, blue: 0.34)   // terracotta
        case .codex:
            return Color(red: 0.16, green: 0.66, blue: 0.53)   // teal
        case .cursor, .cursorAgent:
            return Color(red: 0.42, green: 0.45, blue: 0.90)   // indigo
        case .copilot:
            return Color(red: 0.55, green: 0.58, blue: 0.64)   // graphite
        case .windsurf:
            return Color(red: 0.30, green: 0.70, blue: 0.85)   // cyan
        }
    }

    // ─ Idle severity ────────────────────────────────────────────────────────

    /// Idle time is the number people act on, so it is colour-coded the way a
    /// dashboard would: fine, worth a look, definitely forgotten.
    enum Severity {
        case active, recent, stale, abandoned

        static func of(_ activity: Activity) -> Severity {
            guard let idle = activity.idleFor else { return .active }
            if !activity.isIdle { return .active }
            if idle < 3_600 { return .recent }
            if idle < 86_400 { return .stale }
            return .abandoned
        }

        var color: Color {
            switch self {
            case .active: return Color(red: 0.24, green: 0.70, blue: 0.44)
            case .recent: return Color(red: 0.55, green: 0.58, blue: 0.64)
            case .stale: return Color(red: 0.90, green: 0.66, blue: 0.24)
            case .abandoned: return Color(red: 0.87, green: 0.36, blue: 0.33)
            }
        }

        var label: String {
            switch self {
            case .active: return "working"
            case .recent: return "idle"
            case .stale: return "idle"
            case .abandoned: return "abandoned"
            }
        }
    }

    // ─ Surfaces ─────────────────────────────────────────────────────────────

    static let rowCorner: CGFloat = 10

    static var rowBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color.primary.opacity(0.08) }
    static var subtle: Color { Color.primary.opacity(0.55) }
    static var faint: Color { Color.primary.opacity(0.38) }

    /// Window backdrop — a very slight vertical wash keeps a dense list from
    /// looking like a spreadsheet.
    static var windowBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor).opacity(0.6),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// ─ Small shared views ───────────────────────────────────────────────────────

/// A pill — used for counts, idle state and roles.
struct Pill: View {
    let text: String
    var color: Color = Theme.subtle
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(color.opacity(filled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(filled ? 0.35 : 0.0), lineWidth: 1)
            )
            .foregroundStyle(color)
    }
}

/// A labelled number in the header.
struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.faint)
        }
        .fixedSize()
    }
}


/// The search field, shared by both panes.
struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Theme.hairline, lineWidth: 1)
        )
        .frame(width: 210)
        // ⌘F is where everyone's hand already goes.
        .background(
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
    }
}

/// Shown when a search matched nothing, so an empty pane never reads as
/// "nothing is running".
struct NoMatches: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("Nothing matches \u{201C}\(query)\u{201D}")
                .font(.system(size: 13, weight: .medium))
            Button("Clear search", action: clear)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
