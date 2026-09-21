import AppKit
import SwiftUI

/// Hands a screenshot to whatever app it is dropped on, both as a file and as
/// plain image data, so Finder as well as, say, a text editor or chat app can
/// accept it.
final class ScreenshotDragItem: NSObject, NSPasteboardWriting {
    let url: URL

    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff]
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        // Only read image data when the receiver actually asks for it.
        type == .fileURL ? [] : [.promised]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            return (url as NSURL).pasteboardPropertyList(forType: type)
        case .png:
            if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
            guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        case .tiff:
            return NSImage(contentsOf: url)?.tiffRepresentation
        default:
            return nil
        }
    }
}

/// Keeps track of the screenshot tiles on screen, so a selection gesture that
/// started on one view can find the tile under the pointer.
final class TileRegistry {
    static let shared = TileRegistry()
    private let tiles = NSHashTable<DragOutNSView>.weakObjects()

    func register(_ tile: DragOutNSView) { tiles.add(tile) }

    /// Screenshots whose visible tile touches `windowRect`.
    func items(intersecting windowRect: NSRect, in window: NSWindow?) -> Set<UUID> {
        guard let window else { return [] }
        return Set(tiles.allObjects.compactMap { tile -> UUID? in
            guard tile.window === window, let id = tile.itemID, !tile.isHiddenOrHasHiddenAncestor else { return nil }
            // The visible part only, so tiles scrolled out of view don't count.
            // (visibleRect is unreliable for views hosted inside SwiftUI.)
            var frame = tile.convert(tile.bounds, to: nil)
            if let clip = tile.enclosingScrollView?.contentView {
                frame = frame.intersection(clip.convert(clip.bounds, to: nil))
            }
            return frame.intersects(windowRect) ? id : nil
        })
    }
}

/// A Finder-style selection rectangle, in window coordinates.
struct MarqueeSelection {
    var began: (_ additive: Bool) -> Void = { _ in }
    var changed: (_ rect: NSRect, _ hits: Set<UUID>) -> Void = { _, _ in }
    var ended: () -> Void = {}

    /// Updates the rectangle between the press point and the pointer.
    func update(from start: NSPoint, to event: NSEvent) {
        let end = event.locationInWindow
        // At least 1 pt, so the tile you pressed on counts before you move.
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: max(1, abs(end.x - start.x)), height: max(1, abs(end.y - start.y)))
        changed(rect, TileRegistry.shared.items(intersecting: rect, in: event.window))
    }
}

/// A clickable area drawn by SwiftUI on top of a tile, e.g. the Copy button.
/// `rect` is in the tile's own (bottom-left origin) coordinates.
struct Hotspot: Equatable {
    let id: String
    let rect: NSRect
}

/// Invisible drag area over a screenshot or the stack.
///
/// - Press and move: drags the screenshot(s) into another app, even when the
///   press lands on one of the buttons drawn on top.
/// - Press, hold still briefly, then move: draws a selection rectangle.
/// - Clicks on a hotspot trigger that button; other clicks, ⌘-clicks and
///   double-clicks are reported back.
final class DragOutNSView: NSView, NSDraggingSource {
    var items: () -> [(url: URL, image: NSImage)] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var hotspots: (NSSize) -> [Hotspot] = { _ in [] }
    var onHotspotClick: (String) -> Void = { _ in }
    var onHotspotHover: (String?) -> Void = { _ in }
    /// The right-click menu for this screenshot.
    var menuProvider: (() -> NSMenu?)?
    /// Set for screenshot tiles; nil for the stack, which can't be selected.
    var itemID: UUID? {
        didSet { if itemID != nil { TileRegistry.shared.register(self) } }
    }
    var selection = MarqueeSelection()

    static let holdToSelectDelay: TimeInterval = 0.35

    private enum Mode { case pending, dragging, selecting }
    private var mode = Mode.pending
    private var mouseDownAt: NSPoint = .zero
    private var holdTimer: Timer?

    /// The panel is never active; without this the first click would only focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// Pop the menu up ourselves: a real macOS menu in its own window at the
    /// pointer, rather than anything drawn inside the shelf.
    private func popUpMenu(with event: NSEvent) -> Bool {
        guard let menu = menuProvider?() else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        if !popUpMenu(with: event) { super.rightMouseDown(with: event) }
    }

    private func hotspot(at windowPoint: NSPoint) -> String? {
        let point = convert(windowPoint, from: nil)
        return hotspots(bounds.size).first { $0.rect.contains(point) }?.id
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    // Passing over tiles while dragging or selecting shouldn't pop up their buttons.
    override func mouseEntered(with event: NSEvent) {
        onHover(NSEvent.pressedMouseButtons == 0)
        onHotspotHover(hotspot(at: event.locationInWindow))
    }

    override func mouseMoved(with event: NSEvent) {
        onHotspotHover(hotspot(at: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
        onHotspotHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click.
        if event.modifierFlags.contains(.control), popUpMenu(with: event) { return }
        mouseDownAt = event.locationInWindow
        mode = .pending
        holdTimer?.invalidate()
        guard itemID != nil else { return }
        let additive = event.modifierFlags.contains(.command)
        let timer = Timer(timeInterval: Self.holdToSelectDelay, repeats: false) { [weak self] _ in
            self?.beginSelecting(additive: additive, event: event)
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func beginSelecting(additive: Bool, event: NSEvent) {
        guard mode == .pending, itemID != nil else { return }
        mode = .selecting
        onHover(false)
        selection.began(additive)
        selection.update(from: mouseDownAt, to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .pending:
            let dx = event.locationInWindow.x - mouseDownAt.x
            let dy = event.locationInWindow.y - mouseDownAt.y
            guard abs(dx) > 3 || abs(dy) > 3 else { return }
            holdTimer?.invalidate()
            mode = .dragging
            beginDrag(with: event)
        case .selecting:
            selection.update(from: mouseDownAt, to: event)
        case .dragging:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if mode == .selecting { selection.ended() }
        if mode == .pending {
            if let spot = hotspot(at: event.locationInWindow) {
                // The second click of a double-click shouldn't run the action again.
                if event.clickCount == 1 { onHotspotClick(spot) }
            } else if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onClick(event.modifierFlags)
            }
        }
        mode = .pending
    }

    private func beginDrag(with event: NSEvent) {
        let payload = items()
        guard !payload.isEmpty else { return }

        let side: CGFloat = min(bounds.width, bounds.height)
        let dragging: [NSDraggingItem] = payload.enumerated().map { index, entry in
            let item = NSDraggingItem(pasteboardWriter: ScreenshotDragItem(url: entry.url))
            let offset = CGFloat(index) * 4
            let frame = NSRect(x: bounds.midX - side / 2 + offset,
                               y: bounds.midY - side / 2 - offset,
                               width: side, height: side)
            item.setDraggingFrame(frame, contents: entry.image)
            return item
        }
        beginDraggingSession(with: dragging, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

struct DragOutArea: NSViewRepresentable {
    var items: () -> [(url: URL, image: NSImage)]
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var hotspots: (NSSize) -> [Hotspot] = { _ in [] }
    var onHotspotClick: (String) -> Void = { _ in }
    var onHotspotHover: (String?) -> Void = { _ in }
    var menuProvider: (() -> NSMenu?)?
    var itemID: UUID?
    var selection = MarqueeSelection()

    func makeNSView(context: Context) -> DragOutNSView {
        let view = DragOutNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragOutNSView, context: Context) {
        view.items = items
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.hotspots = hotspots
        view.onHotspotClick = onHotspotClick
        view.onHotspotHover = onHotspotHover
        view.menuProvider = menuProvider
        view.itemID = itemID
        view.selection = selection
    }
}

/// Empty space on the expanded shelf: a click clears the selection, pressing
/// and moving draws a selection rectangle.
final class SelectionCanvasNSView: NSView {
    var onClick: () -> Void = {}
    var selection = MarqueeSelection()
    private var mouseDownAt: NSPoint = .zero
    private var selecting = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        selecting = false
    }

    override func mouseDragged(with event: NSEvent) {
        if !selecting {
            let dx = event.locationInWindow.x - mouseDownAt.x
            let dy = event.locationInWindow.y - mouseDownAt.y
            guard abs(dx) > 3 || abs(dy) > 3 else { return }
            selecting = true
            selection.began(event.modifierFlags.contains(.command))
        }
        selection.update(from: mouseDownAt, to: event)
    }

    override func mouseUp(with event: NSEvent) {
        if selecting { selection.ended() } else { onClick() }
        selecting = false
    }
}

struct SelectionCanvas: NSViewRepresentable {
    var onClick: () -> Void
    var selection: MarqueeSelection

    func makeNSView(context: Context) -> SelectionCanvasNSView {
        let view = SelectionCanvasNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SelectionCanvasNSView, context: Context) {
        view.onClick = onClick
        view.selection = selection
    }
}
