import AppKit
import Combine
import ImageIO

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var thumbnail: NSImage
    var modified: Date?

    static func == (a: ShelfItem, b: ShelfItem) -> Bool { a.id == b.id }
}

/// Holds the screenshots currently on the shelf and moves them to the save
/// folder.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var expanded: Bool = false
    @Published var hovering: Bool = false
    /// Screenshots selected with ⌘-click on the expanded shelf.
    @Published var selection: Set<UUID> = []

    static let stagingURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShotShelf/Staging", isDirectory: true)
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

    // MARK: - Adding

    @discardableResult
    func add(_ url: URL) -> Bool {
        guard !items.contains(where: { $0.url == url }) else { return false }
        guard let thumb = ShelfStore.thumbnail(for: url) else { return false }
        items.append(ShelfItem(url: url, thumbnail: thumb, modified: ShelfStore.modificationDate(of: url)))
        return true
    }

    // MARK: - Selection

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func toggleSelection(_ item: ShelfItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func clearSelection() {
        if !selection.isEmpty { selection.removeAll() }
    }

    /// What an action on `item` applies to: the whole selection if the item is
    /// part of it, otherwise just the item.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id), selection.count > 1 else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    // MARK: - Getting rid of screenshots (saved, or moved to the Trash)

    /// Saves everything to the save folder and empties the shelf. Used on quit,
    /// so it never trashes anything.
    func flushAll() {
        dispose(items, action: .save)
    }

    /// Takes screenshots off the shelf. Files that could not be saved or trashed
    /// stay on the shelf, so nothing is ever lost by accident.
    func dispose(_ targets: [ShelfItem], action: DisposeAction) {
        let failed = Set(targets.filter { !ShelfStore.dispose($0.url, action: action) }.map(\.id))
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
