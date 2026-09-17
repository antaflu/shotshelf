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

    func item(at windowPoint: NSPoint, in window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return tiles.allObjects.first { tile in
            guard tile.window === window, tile.itemID != nil, !tile.isHiddenOrHasHiddenAncestor else { return false }
            // The visible part only, so tiles scrolled out of view don't count.
            // (visibleRect is unreliable for views hosted inside SwiftUI.)
            var frame = tile.convert(tile.bounds, to: nil)
            if let clip = tile.enclosingScrollView?.contentView {
                frame = frame.intersection(clip.convert(clip.bounds, to: nil))
            }
            return frame.contains(windowPoint)
        }?.itemID
    }
}

/// Callbacks for selecting screenshots by moving over them with the button held.
struct PaintSelection {
    var began: (_ additive: Bool) -> Void = { _ in }
    var paint: (UUID) -> Void = { _ in }

    func paint(_ event: NSEvent) {
        if let id = TileRegistry.shared.item(at: event.locationInWindow, in: event.window) { paint(id) }
    }
}

/// Invisible drag area over a screenshot or the stack.
///
/// - Press and move: drags the screenshot(s) into another app.
/// - Press, hold still briefly, then move: selects every screenshot you pass over.
/// - Click, ⌘-click and double-click are reported back.
final class DragOutNSView: NSView, NSDraggingSource {
    var items: () -> [(url: URL, image: NSImage)] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    /// Points (in this view) where SwiftUI buttons drawn on top should get the click.
    var passesThrough: (NSPoint, NSSize) -> Bool = { _, _ in false }
    /// Set for screenshot tiles; nil for the stack, which can't be selected.
    var itemID: UUID? {
        didSet { if itemID != nil { TileRegistry.shared.register(self) } }
    }
    var selection = PaintSelection()

    static let holdToSelectDelay: TimeInterval = 0.35

    private enum Mode { case pending, dragging, selecting }
    private var mode = Mode.pending
    private var mouseDownAt: NSPoint = .zero
    private var holdTimer: Timer?

    /// The panel is never active; without this the first click would only focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        return passesThrough(local, bounds.size) ? nil : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    // Passing over tiles while dragging or selecting shouldn't pop up their buttons.
    override func mouseEntered(with event: NSEvent) { onHover(NSEvent.pressedMouseButtons == 0) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        mode = .pending
        holdTimer?.invalidate()
        guard itemID != nil else { return }
        let additive = event.modifierFlags.contains(.command)
        let timer = Timer(timeInterval: Self.holdToSelectDelay, repeats: false) { [weak self] _ in
            self?.beginSelecting(additive: additive)
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func beginSelecting(additive: Bool) {
        guard mode == .pending, let itemID else { return }
        mode = .selecting
        onHover(false)
        selection.began(additive)
        selection.paint(itemID)
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
            selection.paint(event)
        case .dragging:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if mode == .pending {
            if event.clickCount >= 2 { onDoubleClick() } else { onClick(event.modifierFlags) }
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
    var passesThrough: (NSPoint, NSSize) -> Bool = { _, _ in false }
    var itemID: UUID?
    var selection = PaintSelection()

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
        view.passesThrough = passesThrough
        view.itemID = itemID
        view.selection = selection
    }
}

/// Empty space on the expanded shelf: a click clears the selection, pressing
/// and moving selects every screenshot you pass over.
final class SelectionCanvasNSView: NSView {
    var onClick: () -> Void = {}
    var selection = PaintSelection()
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
        selection.paint(event)
    }

    override func mouseUp(with event: NSEvent) {
        if !selecting { onClick() }
        selecting = false
    }
}

struct SelectionCanvas: NSViewRepresentable {
    var onClick: () -> Void
    var selection: PaintSelection

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
