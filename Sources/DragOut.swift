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

/// Invisible drag area over the stack. A click expands the shelf, a drag takes
/// every screenshot along to another app.
final class DragOutNSView: NSView, NSDraggingSource {
    var items: () -> [(url: URL, image: NSImage)] = { [] }
    var onClick: () -> Void = {}

    private var mouseDownAt: NSPoint = .zero
    private var didDrag = false

    /// The panel is never active; without this the first click would only focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        if !didDrag { onClick() }
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
    var onClick: () -> Void

    func makeNSView(context: Context) -> DragOutNSView {
        let view = DragOutNSView()
        view.items = items
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: DragOutNSView, context: Context) {
        view.items = items
        view.onClick = onClick
    }
}
