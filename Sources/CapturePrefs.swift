import Foundation

/// Reads and writes the macOS screenshot preferences (com.apple.screencapture).
/// ShotShelf temporarily points the save location at its own staging folder and
/// restores the original value when it quits.
enum CapturePrefs {
    private static let domain = "com.apple.screencapture" as CFString

    static func string(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, domain) as? String
    }

    static func bool(_ key: String) -> Bool? {
        CFPreferencesCopyAppValue(key as CFString, domain) as? Bool
    }

    static func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// The screenshot UI caches these preferences; restarting SystemUIServer reloads them.
    static func reloadUI() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["SystemUIServer"]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }
}
