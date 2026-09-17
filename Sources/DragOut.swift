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

/// Invisible drag area over a screenshot or the stack. A drag takes the
/// screenshots along to another app; clicks and hover are reported back.
final class DragOutNSView: NSView, NSDraggingSource {
    var items: () -> [(url: URL, image: NSImage)] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    /// Points (in this view) where SwiftUI buttons drawn on top should get the click.
    var passesThrough: (NSPoint, NSSize) -> Bool = { _, _ in false }

    private var mouseDownAt: NSPoint = .zero
    private var didDrag = false

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

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let dx = event.locationInWindow.x - mouseDownAt.x
        let dy = event.locationInWindow.y - mouseDownAt.y
        guard abs(dx) > 3 || abs(dy) > 3 else { return }
        didDrag = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick(event.modifierFlags) }
        didDrag = false
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
    var onHover: (Bool) -> Void = { _ in }
    var passesThrough: (NSPoint, NSSize) -> Bool = { _, _ in false }

    func makeNSView(context: Context) -> DragOutNSView {
        let view = DragOutNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragOutNSView, context: Context) {
        view.items = items
        view.onClick = onClick
        view.onHover = onHover
        view.passesThrough = passesThrough
    }
}
