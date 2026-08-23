import Foundation

/// What this binary actually is.
///
/// Version and commit hash are stamped into Info.plist by `scripts/make_app.sh`,
/// which CI calls with the released version (`VERSION` plus the run number) and
/// the commit it checked out. `Corral --version` and the About panel read the
/// same two facts, so what the app claims and what a script can check never
/// drift apart.
enum BuildInfo {

    static let repository = "popyapp/corral"

    /// The released version — `0.1.4` from a GitHub build, `0.1` from a local
    /// one, since only CI appends a build number.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The short commit hash, with a `-dirty` suffix when the tree it was built
    /// from had uncommitted changes.
    static var commit: String {
        Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "local"
    }

    static var display: String { "\(version) (\(commit))" }

    /// True when the binary was built from a working tree with uncommitted
    /// changes, so it corresponds to no commit at all.
    static var isDirty: Bool { commit.hasSuffix("-dirty") }

    /// A released build carries a build number appended by CI, so its version
    /// has three components where a local build has two. Not a guarantee —
    /// someone can put anything in `VERSION` — but it is the difference between
    /// what a download reports and what `make app` reports, which is the
    /// question people actually have.
    static var isReleaseBuild: Bool {
        // A local build carries git's "+<commits since the tag>" suffix, so it
        // is a released number plus something — which is not a release.
        !isDirty && !version.contains("+") && version.split(separator: ".").count >= 3
    }

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    /// The rest of the apps this one belongs to.
    static var homeURL: URL { URL(string: "https://popy.app")! }

    /// The exact commit this was built from, when there is one to point at.
    static var commitURL: URL? {
        guard !isDirty else { return nil }
        let hash = commit
        // Only a real hash is worth linking; "local" and "unknown" are the
        // fallbacks make_app.sh writes when git cannot answer.
        guard hash.count >= 7,
              hash.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return URL(string: "https://github.com/\(repository)/commit/\(hash)")
    }
}
