import AppKit
import Combine
import ImageIO

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var thumbnail: NSImage
    var modified: Date?
    /// When the screenshot was taken, or the dropped file was made.
    var date = Date()
    /// A file you dragged in from somewhere on disk. ShotShelf only points to
    /// it: closing or trashing just takes it off the shelf, the original stays.
    var isReference = false

    static func == (a: ShelfItem, b: ShelfItem) -> Bool { a.id == b.id }
}

/// One shelf: a name, an icon and what's on it.
struct Shelf: Identifiable {
    let id: UUID
    var name: String
    var symbol: ShelfSymbol
    var items: [ShelfItem]

    init(id: UUID = UUID(), name: String, symbol: ShelfSymbol = .none, items: [ShelfItem] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.items = items
    }
}

/// Holds every shelf, and saves or trashes the files ShotShelf owns.
final class ShelfStore: ObservableObject {
    @Published var shelves: [Shelf] = [Shelf(name: "Shelf 1")]
    @Published var currentIndex = 0

    /// What's on the shelf you're looking at.
    var items: [ShelfItem] {
        get { shelves.indices.contains(currentIndex) ? shelves[currentIndex].items : [] }
        set {
            guard shelves.indices.contains(currentIndex) else { return }
            shelves[currentIndex].items = newValue
        }
    }
    var current: Shelf { shelves.indices.contains(currentIndex) ? shelves[currentIndex] : shelves[0] }
    @Published var expanded: Bool = false
    @Published var hovering: Bool = false
    /// True while something droppable is dragged over the shelf.
    @Published var dropTargeted: Bool = false
    /// Screenshots selected with ⌘-click on the expanded shelf.
    @Published var selection: Set<UUID> = []

    static let stagingURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShotShelf/Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Images dropped onto the shelf without a file of their own (e.g. from a
    /// browser) are written here. Not watched, so they don't touch the clipboard.
    static let droppedURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShotShelf/Dropped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The folder from Settings (the Desktop by default).
    static var destinationURL: URL {
        let folder = AppSettings.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var isEmpty: Bool { items.isEmpty }
    /// Every screenshot on every shelf, e.g. to check a file is still in use.
    var allItems: [ShelfItem] { shelves.flatMap(\.items) }

    // MARK: - Shelves

    /// More than a handful and the header runs out of room.
    static let maxShelves = 6

    var canAddShelf: Bool { shelves.count < ShelfStore.maxShelves }

    func select(_ index: Int) {
        guard shelves.indices.contains(index), index != currentIndex else { return }
        selection.removeAll()
        currentIndex = index
    }

    @discardableResult
    func addShelf() -> Int {
        guard canAddShelf else { return currentIndex }
        shelves.append(Shelf(name: "Shelf \(shelves.count + 1)"))
        return shelves.count - 1
    }

    /// Only ever removes an empty shelf, and never the last one.
    func removeShelf(at index: Int) {
        guard shelves.count > 1, shelves.indices.contains(index), shelves[index].items.isEmpty else { return }
        shelves.remove(at: index)
        currentIndex = min(currentIndex, shelves.count - 1)
    }

    func move(_ moving: [ShelfItem], toShelf index: Int) {
        guard shelves.indices.contains(index) else { return }
        let ids = Set(moving.map(\.id))
        var moved: [ShelfItem] = []
        for shelfIndex in shelves.indices {
            moved += shelves[shelfIndex].items.filter { ids.contains($0.id) }
            shelves[shelfIndex].items.removeAll { ids.contains($0.id) }
        }
        shelves[index].items += moved
        selection.subtract(ids)
        if items.isEmpty { expanded = false }
    }

    // MARK: - Adding

    @discardableResult
    func add(_ url: URL, isReference: Bool = false) -> Bool {
        let url = url.standardizedFileURL
        guard !items.contains(where: { $0.url.standardizedFileURL == url }) else { return false }
        guard let thumb = ShelfStore.thumbnail(for: url) else { return false }
        items.append(ShelfItem(url: url, thumbnail: thumb, modified: ShelfStore.modificationDate(of: url),
                               date: ShelfStore.date(of: url), isReference: isReference))
        return true
    }

    // MARK: - Grouping by date

    /// Screenshots grouped the way Photos does it: Today, Yesterday, Last week,
    /// 2 weeks ago, and months further back. Newest first.
    var groups: [ShelfGroup] {
        let sorted = items.sorted { $0.date > $1.date }
        var result: [ShelfGroup] = []
        for item in sorted {
            let title = ShelfGroup.title(for: item.date)
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append(ShelfGroup(title: title, items: [item]))
            }
        }
        return result
    }

    // MARK: - Selection

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func toggleSelection(_ item: ShelfItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func clearSelection() {
        if !selection.isEmpty { selection.removeAll() }
    }

    /// The selection rectangle being drawn, in window coordinates.
    @Published private(set) var marquee: NSRect?
    private var selectionBeforeMarquee: Set<UUID> = []

    /// Like Finder: screenshots inside the rectangle are selected, and drop out
    /// again when the rectangle shrinks. With ⌘ they add to what was selected.
    var marqueeSelection: MarqueeSelection {
        MarqueeSelection(
            began: { [weak self] additive in
                guard let self else { return }
                self.selectionBeforeMarquee = additive ? self.selection : []
            },
            changed: { [weak self] rect, hits in
                guard let self else { return }
                self.marquee = rect
                let updated = self.selectionBeforeMarquee.union(hits)
                if updated != self.selection { self.selection = updated }
            },
            ended: { [weak self] in self?.marquee = nil })
    }

    /// What an action on `item` applies to: the whole selection if the item is
    /// part of it, otherwise just the item.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id), selection.count > 1 else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    // MARK: - Getting rid of screenshots (saved, or moved to the Trash)

    /// Saves everything to the save folder and empties the shelf. Used on quit,
    /// so it never trashes anything. Dragged-in files are just let go.
    func flushAll() {
        dispose(items, action: .save)
    }

    /// Takes screenshots off every shelf, wherever they are.
    func disposeEverywhere(_ targets: [ShelfItem], action: DisposeAction) {
        let ids = Set(targets.map(\.id))
        let saved = currentIndex
        for index in shelves.indices where shelves[index].items.contains(where: { ids.contains($0.id) }) {
            currentIndex = index
            dispose(shelves[index].items.filter { ids.contains($0.id) }, action: action)
        }
        currentIndex = min(saved, shelves.count - 1)
    }

    /// Takes screenshots off the shelf. Files that could not be saved or trashed
    /// stay on the shelf, so nothing is ever lost by accident.
    func dispose(_ targets: [ShelfItem], action: DisposeAction) {
        let failed = Set(targets.filter { !$0.isReference && !ShelfStore.dispose($0.url, action: action) }.map(\.id))
        let removed = Set(targets.map(\.id)).subtracting(failed)
        items.removeAll { removed.contains($0.id) }
        selection.subtract(removed)
        if items.isEmpty { expanded = false }
    }

    /// True when the file is gone from the shelf's point of view: saved,
    /// trashed, or already deleted outside the app.
    private static func dispose(_ url: URL, action: DisposeAction) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        switch action {
        case .save:
            return moveToDestination(url) != nil
        case .trash:
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return true
            } catch {
                NSLog("ShotShelf: could not move %@ to the Trash: %@", url.path, String(describing: error))
                return false
            }
        }
    }

    // MARK: - Quick actions

    func copy(_ targets: [ShelfItem]) {
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            ShelfStore.copyToPasteboard(targets[0].url)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(targets.map { ScreenshotDragItem(url: $0.url) })
        }
    }

    func openInPreview(_ targets: [ShelfItem]) {
        let urls = targets.map(\.url)
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open(urls, withApplicationAt: preview, configuration: configuration)
        } else {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    /// Reloads thumbnails of files that changed, e.g. after editing in Preview.
    func refreshThumbnails() {
        for index in items.indices {
            let url = items[index].url
            let modified = ShelfStore.modificationDate(of: url)
            guard modified != items[index].modified, let thumb = ShelfStore.thumbnail(for: url) else { continue }
            items[index].thumbnail = thumb
            items[index].modified = modified
        }
    }

    /// Newest date wins: a screenshot edited in Preview stays where you expect it.
    static func date(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    static func modificationDate(of url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    @discardableResult
    static func moveToDestination(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let destination = uniqueDestination(for: url.lastPathComponent, in: destinationURL)
        do {
            try fm.moveItem(at: url, to: destination)
            return destination
        } catch {
            // If moving fails (another volume, missing permissions), copy instead.
            if (try? fm.copyItem(at: url, to: destination)) != nil {
                try? fm.removeItem(at: url)
                return destination
            }
            NSLog("ShotShelf: could not move %@ to the save folder: %@", url.path, String(describing: error))
            return nil
        }
    }

    private static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: - Thumbnails

    static func thumbnail(for url: URL, maxPixel: Int = 512) -> NSImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(contentsOf: url)
    }

    // MARK: - Clipboard

    /// Puts the screenshot on the clipboard as an image, so it can be pasted
    /// anywhere right away.
    static func copyToPasteboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = pngData(from: image, fileURL: url) {
            pb.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    private static func pngData(from image: NSImage, fileURL: URL) -> Data? {
        if fileURL.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: fileURL) {
            return data
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
