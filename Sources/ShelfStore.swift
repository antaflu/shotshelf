import AppKit
import Combine
import ImageIO

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var thumbnail: NSImage

    static func == (a: ShelfItem, b: ShelfItem) -> Bool { a.id == b.id }
}

/// Holds the screenshots currently on the shelf and moves them to the save
/// folder.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var expanded: Bool = false
    @Published var hovering: Bool = false

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
        items.append(ShelfItem(url: url, thumbnail: thumb))
        return true
    }

    // MARK: - Saving (always to the save folder, never deleted)

    /// Moves everything to the save folder and empties the shelf. Screenshots
    /// that could not be moved stay put, so nothing is ever lost.
    func flushAll() {
        items = items.filter { ShelfStore.keepAfterFlush($0) }
        if items.isEmpty { expanded = false }
    }

    /// Moves one screenshot to the save folder and takes it off the shelf.
    func flush(_ item: ShelfItem) {
        guard !ShelfStore.keepAfterFlush(item) else { return }
        items.removeAll { $0.id == item.id }
        if items.isEmpty { expanded = false }
    }

    /// A screenshot stays on the shelf only if its file still exists and moving
    /// it failed. A file that disappeared outside the app is simply dropped.
    private static func keepAfterFlush(_ item: ShelfItem) -> Bool {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return false }
        return moveToDestination(item.url) == nil
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
