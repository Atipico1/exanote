import Foundation

/// Where Exanote keeps audio, models, the IPC token and settings. The Python worker, CLI and MCP
/// server resolve the same folder in src/exanote/paths.py.
enum AppPaths {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let legacyData = home.appending(path: ".local/share/open-notes")
    private static let legacyBundleID = "app.opennotes.macos"

    static var data: URL {
        ProcessInfo.processInfo.environment["EXANOTE_DATA"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".local/share/exanote")
    }

    /// Runs once at launch, before the worker starts. Carries recordings, downloaded models and
    /// settings over from the Open Notes build so nothing is lost or downloaded again.
    static func migrateFromOpenNotes() {
        let files = FileManager.default
        if ProcessInfo.processInfo.environment["EXANOTE_DATA"] == nil,
           files.fileExists(atPath: legacyData.path), !files.fileExists(atPath: data.path) {
            do {
                try files.moveItem(at: legacyData, to: data)
                // A local workspace is stored as an absolute path inside the old folder.
                let settings = data.appending(path: "settings.json")
                if let text = try? String(contentsOf: settings, encoding: .utf8) {
                    try? text.replacingOccurrences(of: legacyData.path, with: data.path)
                        .write(to: settings, atomically: true, encoding: .utf8)
                }
            } catch {
                NSLog("Exanote: could not move \(legacyData.path): \(error)")
            }
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "appearance") == nil,
           let appearance = UserDefaults(suiteName: legacyBundleID)?.string(forKey: "appearance") {
            defaults.set(appearance, forKey: "appearance")
        }
    }
}
