import AppKit

/// Keeps your shelves on disk, so they survive quitting and updating, and
/// reads and writes `.shelf` files you can keep or pass around.
enum ShelfStorage {
    static let fileExtension = "shelf"

    /// A `var` so tests can point the library somewhere harmless.
    static var libraryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShotShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Shelves.json")
    }()

    /// Where the contents of imported `.shelf` files are unpacked.
    static var importedURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShotShelf/Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - On-disk shape

    private struct StoredItem: Codable {
        var path: String
        var date: Date
        var isReference: Bool
    }

    private struct StoredShelf: Codable {
        var id: UUID
        var name: String
        var symbol: ShelfSymbol
        var items: [StoredItem]
    }

    private struct StoredLibrary: Codable {
        var shelves: [StoredShelf]
        var currentIndex: Int
    }

    private static func stored(_ shelf: Shelf) -> StoredShelf {
        StoredShelf(id: shelf.id, name: shelf.name, symbol: shelf.symbol,
                    items: shelf.items.map { StoredItem(path: $0.url.path, date: $0.date, isReference: $0.isReference) })
    }

    /// Rebuilds a shelf, skipping anything whose file has since disappeared.
    private static func shelf(from stored: StoredShelf) -> Shelf {
        var shelf = Shelf(id: stored.id, name: stored.name, symbol: stored.symbol)
        for entry in stored.items {
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let thumbnail = ShelfStore.thumbnail(for: url) else { continue }
            shelf.items.append(ShelfItem(url: url, thumbnail: thumbnail,
                                         modified: ShelfStore.modificationDate(of: url),
                                         date: entry.date, isReference: entry.isReference))
        }
        return shelf
    }

    // MARK: - The library

    static func save(_ store: ShelfStore) {
        let library = StoredLibrary(shelves: store.shelves.map(stored), currentIndex: store.currentIndex)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: libraryURL, options: .atomic)
        } catch {
            NSLog("ShotShelf: could not save the shelves: %@", String(describing: error))
        }
    }

    static func load(into store: ShelfStore) {
        guard let data = try? Data(contentsOf: libraryURL),
              let library = try? JSONDecoder().decode(StoredLibrary.self, from: data),
              !library.shelves.isEmpty else { return }
        var shelves = library.shelves.map(shelf(from:))
        var index = min(max(0, library.currentIndex), shelves.count - 1)

        // Libraries from before shelves could be switched hold a single shelf:
        // give them the Starred shelf and a spare, keeping their screenshots.
        if shelves.count == 1, ["Shelf 1", "Starred"].contains(shelves[0].name) {
            var defaults = ShelfStore.defaultShelves()
            defaults[ShelfStore.defaultIndex].items = shelves[0].items
            shelves = defaults
            index = ShelfStore.defaultIndex
        }
        store.shelves = shelves
        store.currentIndex = index
    }

    // MARK: - .shelf files

    private struct Manifest: Codable {
        var name: String
        var symbol: ShelfSymbol
        var items: [Entry]

        struct Entry: Codable {
            var file: String
            var date: Date
        }
    }

    /// Writes a `.shelf`: a zip holding a copy of every image plus a manifest,
    /// so it keeps working on another Mac.
    static func export(_ shelf: Shelf, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfExport-\(UUID().uuidString)", isDirectory: true)
        let files = staging.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var entries: [Manifest.Entry] = []
        for (index, item) in shelf.items.enumerated() {
            guard FileManager.default.fileExists(atPath: item.url.path) else { continue }
            // Numbered so two screenshots with the same name can't collide.
            let name = String(format: "%03d-%@", index + 1, item.url.lastPathComponent)
            try FileManager.default.copyItem(at: item.url, to: files.appendingPathComponent(name))
            entries.append(Manifest.Entry(file: name, date: item.date))
        }
        let manifest = Manifest(name: shelf.name, symbol: shelf.symbol, items: entries)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try? FileManager.default.removeItem(at: destination)
        guard run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]) else {
            throw Failure.message("Could not write \(destination.lastPathComponent).")
        }
    }

    /// Unpacks a `.shelf` into the app's own storage and returns it as a shelf.
    static func importShelf(from url: URL) throws -> Shelf {
        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        guard run("/usr/bin/ditto", ["-x", "-k", url.path, unpacked.path]),
              let data = try? Data(contentsOf: unpacked.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw Failure.message("\(url.lastPathComponent) is not a shelf file.")
        }

        let folder = importedURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shelf = Shelf(name: manifest.name, symbol: manifest.symbol)
        for entry in manifest.items {
            let source = unpacked.appendingPathComponent("Files/\(entry.file)")
            let destination = folder.appendingPathComponent(entry.file)
            guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil,
                  let thumbnail = ShelfStore.thumbnail(for: destination) else { continue }
            shelf.items.append(ShelfItem(url: destination, thumbnail: thumbnail,
                                         modified: ShelfStore.modificationDate(of: destination),
                                         date: entry.date, isReference: false))
        }
        guard !shelf.items.isEmpty else { throw Failure.message("\(url.lastPathComponent) holds no images.") }
        return shelf
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
