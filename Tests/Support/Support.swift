import AppKit

/// Small helpers shared by the test suites.
enum Check {
    static var failures = 0

    static func ok(_ passed: Bool, _ label: String) {
        print(passed ? "  ✓" : "  ✗", label)
        if !passed { failures += 1 }
    }

    static func section(_ name: String) { print(name) }

    static func finish() -> Never {
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// RunLoop.run(until:) returns early when nothing is scheduled, so spin.
func spin(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        usleep(2000)
    }
}

/// A throwaway folder, and stand-in screenshots to put on the shelf.
enum Fixtures {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotShelfTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var counter = 0

    @discardableResult
    static func image(hue: Double = 0.6, named: String? = nil, date: Date? = nil) -> URL {
        counter += 1
        let url = folder.appendingPathComponent(named ?? "shot-\(counter).png")
        let width = 600, height = 400
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: 60, y: 60, width: 200, height: 110))
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try! png.write(to: url)
        if let date {
            try! FileManager.default.setAttributes([.creationDate: date, .modificationDate: date],
                                                   ofItemAtPath: url.path)
        }
        return url
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Keeps the tests away from the real shelves and the real Trash leftovers.
    static func isolateStorage() {
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        ShelfStorage.libraryURL = folder.appendingPathComponent("Shelves.json")
        ShelfStorage.importedURL = folder.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: ShelfStorage.importedURL, withIntermediateDirectories: true)
        AppSettings.shared.saveFolder = folder.appendingPathComponent("Saved", isDirectory: true)
        try? FileManager.default.createDirectory(at: AppSettings.shared.saveFolder, withIntermediateDirectories: true)
    }

    static func emptyTrashOf(_ names: [String]) {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0]
        for name in names { try? FileManager.default.removeItem(at: trash.appendingPathComponent(name)) }
    }
}
