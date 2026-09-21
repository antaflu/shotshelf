import AppKit
import UniformTypeIdentifiers

/// Turns whatever is dropped on the shelf into shelf items.
///
/// - Image files from disk are added as references: the original is never
///   moved or trashed.
/// - Promised files (e.g. an image dragged out of a browser) and raw image data
///   are written to the Dropped folder and then behave like screenshots.
enum ShelfDropHandler {
    static let acceptedTypes: [UTType] = [.image, .pdf]

    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    private static var fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true,
         .urlReadingContentsConformToTypes: acceptedTypes.map(\.identifier)]
    }

    /// Whether the pasteboard holds anything the shelf can keep.
    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLOptions)
            || promises(on: pasteboard).contains { promise in
                promise.fileTypes.contains { UTType($0).map(conforms) ?? false }
            }
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Adds the dropped content to `store`. Promised files arrive later, so
    /// `completion` reports how many items were added once everything is in.
    @discardableResult
    static func accept(_ pasteboard: NSPasteboard, into store: ShelfStore,
                       completion: @escaping (Int) -> Void = { _ in }) -> Bool {
        // 1. Files on disk: keep a reference.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [URL],
           !urls.isEmpty {
            let added = urls.filter { store.add($0, isReference: true) }.count
            completion(added)
            return added > 0
        }

        // 2. Promised files: let the source write them into the Dropped folder.
        let accepted = promises(on: pasteboard).filter { promise in
            promise.fileTypes.contains { UTType($0).map(conforms) ?? false }
        }
        if !accepted.isEmpty {
            let group = DispatchGroup()
            var received: [URL] = []
            let lock = NSLock()
            for promise in accepted {
                group.enter()
                promise.receivePromisedFiles(atDestination: ShelfStore.droppedURL, options: [:],
                                             operationQueue: promiseQueue) { url, error in
                    if error == nil {
                        lock.lock(); received.append(url); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                completion(received.filter { store.add($0) }.count)
            }
            return true
        }

        // 3. Raw image data: write it out as a PNG.
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
           let url = writePNG(image) {
            let added = store.add(url)
            completion(added ? 1 : 0)
            return added
        }
        completion(0)
        return false
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private static func promises(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    private static func conforms(_ type: UTType) -> Bool {
        acceptedTypes.contains { type.conforms(to: $0) }
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private static func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let base = "Image \(nameFormatter.string(from: Date()))"
        var url = ShelfStore.droppedURL.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = ShelfStore.droppedURL.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        return (try? png.write(to: url)) != nil ? url : nil
    }
}

/// The menu you get when right-clicking somewhere on the shelf that isn't a
/// screenshot: paste whatever is on the clipboard onto this shelf.
enum ShelfMenus {
    static func paste(into store: ShelfStore) -> NSMenu {
        let menu = NSMenu()
        menu.addAction("Paste", enabled: ShelfDropHandler.canAccept(.general)) {
            ShelfDropHandler.accept(.general, into: store)
        }
        return menu
    }
}

/// The panel's content view: hosts the SwiftUI shelf and accepts drops on it.
final class ShelfDropView: NSView {
    let store: ShelfStore
    /// Called as soon as a drop is accepted (promised files may still be on their way).
    var onDropAccepted: () -> Void = {}

    init(store: ShelfStore, content: NSView) {
        self.store = store
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes(ShelfDropHandler.draggedTypes)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Drags that start on the shelf itself are never dropped back onto it.
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        info.draggingSource == nil && ShelfDropHandler.canAccept(info.draggingPasteboard)
    }

    override func menu(for event: NSEvent) -> NSMenu? { ShelfMenus.paste(into: store) }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(ShelfMenus.paste(into: store), with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        store.dropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        store.dropTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        store.dropTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        store.dropTargeted = false
        guard accepts(sender) else { return false }
        let accepted = ShelfDropHandler.accept(sender.draggingPasteboard, into: store)
        if accepted { onDropAccepted() }
        return accepted
    }
}

/// Brings the shelf out while you drag something droppable towards its corner,
/// and puts it away again if you let go elsewhere.
final class DragRevealWatcher {
    var onReveal: () -> Void = {}
    var onDragEnded: () -> Void = {}
    /// Where the pointer is; replaceable for testing.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    private var timer: Timer?
    private var lastDragChange = NSPasteboard(name: .drag).changeCount
    private var buttonWasDown = false
    private var revealed = false

    func start() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1
        defer { buttonWasDown = buttonDown }
        let pasteboard = NSPasteboard(name: .drag)

        guard buttonDown else {
            if buttonWasDown {
                // Anything on the drag pasteboard from now on is a new drag.
                lastDragChange = pasteboard.changeCount
                if revealed {
                    revealed = false
                    onDragEnded()
                }
            }
            return
        }
        let settings = AppSettings.shared
        guard settings.revealOnDrag, !revealed,
              pasteboard.changeCount != lastDragChange,
              isNearAnchorCorner(settings.anchorCorner),
              ShelfDropHandler.canAccept(pasteboard) else { return }
        revealed = true
        onReveal()
    }

    private func isNearAnchorCorner(_ corner: ScreenCorner) -> Bool {
        let p = pointerLocation()
        guard let frame = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })?.frame else { return false }
        let dx = corner.isLeft ? p.x - frame.minX : frame.maxX - p.x
        let dy = corner.isTop ? frame.maxY - p.y : p.y - frame.minY
        return max(dx, dy) <= ToggleTriggers.cornerScrollZone
    }
}
