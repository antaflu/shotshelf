import AppKit
import SwiftUI

/// Keeps a view's hover state honest. Entered/exited events alone can go
/// missing: when the shelf resizes or moves under a pointer that's standing
/// still, or a window goes away. So while a view believes it's hovered, it
/// checks every so often where the pointer really is.
final class HoverWatch {
    private weak var view: NSView?
    private let ignoreWhilePressed: Bool
    private let onChange: (Bool) -> Void
    private var timer: Timer?
    private(set) var isHovering = false

    init(view: NSView, ignoreWhilePressed: Bool, onChange: @escaping (Bool) -> Void) {
        self.view = view
        self.ignoreWhilePressed = ignoreWhilePressed
        self.onChange = onChange
    }

    deinit { timer?.invalidate() }

    var pointerInside: Bool {
        guard let view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else {
            return false
        }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return view.bounds.contains(point)
    }

    private var buttonHeld: Bool { ignoreWhilePressed && NSEvent.pressedMouseButtons != 0 }

    func entered() { set(pointerInside && !buttonHeld) }
    func exited() { set(false) }

    private func set(_ hovering: Bool) {
        if hovering { startChecking() } else { stopChecking() }
        guard hovering != isHovering else { return }
        isHovering = hovering
        onChange(hovering)
    }

    private func startChecking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.pointerInside || self.buttonHeld { self.set(false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopChecking() {
        timer?.invalidate()
        timer = nil
    }
}

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

        private lazy var watch = HoverWatch(view: self, ignoreWhilePressed: false) { [weak self] in
            self?.onChange($0)
        }

        override func mouseEntered(with event: NSEvent) { watch.entered() }
        override func mouseExited(with event: NSEvent) { watch.exited() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { watch.exited() }
        }
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
