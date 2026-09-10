import AppKit
import Combine
import Foundation

/// The switch for asking Kiro, and the dialog in front of it.
///
/// Arranged like `StatusLineSetup`: nothing happens until a dialog has said,
/// in plain words, exactly what will be read and exactly where it will be
/// sent, and the person has said yes. Turning it off needs no dialog, and
/// forgets what was fetched.
@MainActor
final class KiroAccountSettings: ObservableObject {
    static let shared = KiroAccountSettings()

    /// Mirrors `KiroAccount.isEnabled` so menus and the Usage tab redraw when
    /// it changes. The store reads the setting itself; this is the view of it.
    @Published private(set) var isEnabled: Bool = KiroAccount.isEnabled

    private init() {}

    fileprivate func set(_ enabled: Bool) {
        KiroAccount.isEnabled = enabled
        isEnabled = enabled
    }
}

@MainActor
enum KiroAccountSetup {

    static let title = "Ask Kiro for Account Usage"

    /// Turn it on, after asking.
    static func offer() {
        guard !KiroAccount.isEnabled else {
            tell(
                "Already on",
                "Corral is asking Kiro's servers for the account's credits every five "
                    + "minutes. Turn it off from the same menu."
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Ask Kiro what your account has left?"
        alert.informativeText = """
            Kiro does not write its balance anywhere on this Mac. The Kiro IDE shows \
            one by asking Kiro's servers, and Corral can do the same.

            This is the only thing in Corral that uses the network, and it stays off \
            until you say yes here.

            What it does, every five minutes:

            • Reads the sign-in token Kiro CLI keeps in its own store, \
            ~/Library/Application Support/kiro-cli/data.sqlite3. The token is used \
            for one request and is never written down, logged or shown.

            • Sends one HTTPS request to \(KiroAccount.endpoints[KiroAccount.defaultRegion]!.host ?? "AWS") \
            (or Kiro's EU host, if that is where your profile is) — the same \
            GetUsageLimits call the Kiro IDE makes. Nothing about your projects or \
            conversations goes with it.

            • Keeps the numbers that come back: credits used, the plan's limit, when \
            it resets, and any bonus pool.

            Corral never refreshes the token. When it runs out, running Kiro CLI \
            refreshes it and Corral picks that up.
            """
        alert.addButton(withTitle: "Ask Kiro")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        KiroAccountSettings.shared.set(true)
        KiroAccountStore.shared.refreshIfDue(force: true)
    }

    /// Turn it off. No dialog: stopping needs no explanation, and the figures
    /// it fetched go with it.
    static func turnOff() {
        KiroAccountSettings.shared.set(false)
        KiroAccountStore.shared.forget()
    }

    static func toggle() {
        KiroAccount.isEnabled ? turnOff() : offer()
    }

    /// One sentence on where things stand, for the Usage tab.
    static func summary(now: Date = Date()) -> String {
        switch KiroAccountStore.shared.status {
        case .off:
            return "Not asked. Kiro keeps the balance on its servers; Corral can ask "
                + "for it every five minutes, using Kiro CLI's own sign-in, if you turn "
                + "that on. It is the only thing in Corral that uses the network."
        case .asking:
            return "Asking Kiro's servers now."
        case .answered(let at):
            let age = now.timeIntervalSince(at)
            return "Asking Kiro's servers every five minutes. Last answer "
                + (age < 90 ? "just now." : "\(age.durationString) ago.")
        case .failed(let reason, let at):
            let age = now.timeIntervalSince(at)
            return "\(reason) Last tried \(age < 90 ? "just now" : "\(age.durationString) ago")."
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
