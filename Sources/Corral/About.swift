import AppKit

/// The About panel.
///
/// macOS composes the standard panel from `CFBundleShortVersionString` and
/// `CFBundleVersion` — the "Version 16.0 (16A242d)" pattern every Apple app
/// uses. Corral's packaging script writes the same string into both, so the
/// default panel said "Version 0.1.4 (0.1.4)": the redundant half where the
/// build identifier belongs, and no sign of which commit you are running.
///
/// So the panel is given the real pair: the released version, and the commit it
/// was built from. Below that, the credits carry the hash again as a link
/// straight to that commit on GitHub, because "which build is this" is a
/// question you ask when something looks wrong, and the useful answer is one
/// you can click.
enum AboutPanel {

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: BuildInfo.version,
            .version: BuildInfo.commit,
            .credits: credits(),
        ])
    }

    private static func credits() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString()

        text.append(NSAttributedString(
            string: "Activity Monitor for your local AI agents.\n\n",
            attributes: [
                .font: body,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))

        text.append(NSAttributedString(
            string: "Build ",
            attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]
        ))

        // The hash links to the exact commit when we know it came from a real
        // build; a local or unknown build has nothing to point at.
        let hash = NSMutableAttributedString(
            string: BuildInfo.commit,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let url = BuildInfo.commitURL {
            hash.addAttributes(
                [.link: url, .foregroundColor: NSColor.linkColor],
                range: NSRange(location: 0, length: hash.length)
            )
        }
        text.append(hash)

        if BuildInfo.isDirty {
            text.append(NSAttributedString(
                string: "\nBuilt from a modified working tree — this binary does "
                    + "not match any commit.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.systemOrange,
                ]
            ))
        } else if !BuildInfo.isReleaseBuild {
            text.append(NSAttributedString(
                string: "\nLocal build. Released versions carry a build number "
                    + "(0.1.4), not just the base version.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }

        text.append(NSAttributedString(
            string: "\n\ngithub.com/popyapp/corral",
            attributes: [
                .font: body,
                .foregroundColor: NSColor.linkColor,
                .link: BuildInfo.repositoryURL,
            ]
        ))

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        text.addAttribute(
            .paragraphStyle,
            value: centred,
            range: NSRange(location: 0, length: text.length)
        )
        return text
    }
}
