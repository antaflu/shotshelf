import AppKit
import SwiftUI

/// Reports whether the pointer is over a view. Works even when ShotShelf is not
/// the active app (SwiftUI's onHover is unreliable in a non-activating panel),
/// and never swallows clicks itself.
struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }
}

/// Draws the chosen symbol on a dark squircle for the Dock.
enum DockIcon {
    static func image(for choice: IconChoice) -> NSImage? {
        guard choice != .stack else { return nil } // default: the bundle icon

        let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = choice.symbol.withSymbolConfiguration(config) else { return nil }

        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            let body = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)
            let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.height * 0.2237)
            NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.34, alpha: 1),
                       ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1))?
                .draw(in: path, angle: -90)

            let size = symbol.size
            let scale = min(body.width * 0.52 / size.width, body.height * 0.52 / size.height)
            let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
            symbol.draw(in: NSRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                                   width: drawSize.width, height: drawSize.height))
            return true
        }
    }
}
