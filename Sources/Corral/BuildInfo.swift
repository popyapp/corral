import Foundation

/// Version and git commit hash stamped into Info.plist by scripts/make_app.sh.
/// Users can verify what they're running with `Corral --version`.
enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var commit: String {
        Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "local"
    }

    static var display: String { "\(version) (\(commit))" }
}
