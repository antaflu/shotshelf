import AppKit
import Combine
import SwiftUI

/// A floating panel that never steals focus from the app you are working in.
final class ShelfPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The size of the visible shelf inside its window. Changes of size are
/// animated here, in SwiftUI, together with the screenshots sliding in, rather
/// than by animating the window: two animation systems at once drift apart and
/// look jumpy.
final class ShelfFrame: ObservableObject {
    @Published var size: CGSize = ShelfLayout.collapsed
    @Published var corner: ScreenCorner = .bottomRight

    /// The shelf hugs the corner it's anchored to while the window is larger.
    var alignment: Alignment {
        switch corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

struct ShelfRoot: View {
    @ObservedObject var frame: ShelfFrame
    let shelf: ShelfView

    var body: some View {
        ZStack(alignment: frame.alignment) {
            Color.clear
            shelf.frame(width: frame.size.width, height: frame.size.height)
        }
    }
}

/// Shows, positions, hides and swipes away the shelf.
final class ShelfController {
    let store = ShelfStore()
    var onOpenSettings: () -> Void = {}
    var onSaveShelf: (Shelf) -> Void = { _ in }
    var onOpenShelf: () -> Void = {}

    private let settings = AppSettings.shared
    private var panel: ShelfPanelWindow?
    let frameModel = ShelfFrame()
    private var layoutGeneration = 0
    private var shadowTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var dragOrigin: NSPoint?
    private var dragStartMouse: NSPoint?
    /// While the shelf slides away, layout must not pull it back into place.
    private var slidingOut = false
    /// Where the pointer is; replaceable for testing.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// An empty shelf only stays up when you summoned it yourself (shortcut or hot corner).
    private var allowEmpty = false
    private let margin: CGFloat = 20
    private let revealWatcher = DragRevealWatcher()
    /// The shelf came out because something was dragged to its corner.
    private var revealedForDrop = false
    private var droppedDuringReveal = false

    init() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout(animated: true) }
            .store(in: &cancellables)
        Publishers.Merge(settings.$anchorCorner.map { _ in () }, settings.$thumbnailSize.map { _ in () })
            .dropFirst(2)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout(animated: true) }
            .store(in: &cancellables)

        revealWatcher.onReveal = { [weak self] in self?.revealForDrop() }
        revealWatcher.onDragEnded = { [weak self] in self?.dragRevealEnded() }
        revealWatcher.start()
    }

    // MARK: - Dropping onto the shelf

    private func revealForDrop() {
        guard !isVisible else { return }
        revealedForDrop = true
        droppedDuringReveal = false
        show(allowEmpty: true)
    }

    /// Nothing dropped? Put the shelf away again, just as it was.
    private func dragRevealEnded() {
        guard revealedForDrop else { return }
        revealedForDrop = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.droppedDuringReveal, self.isVisible else { return }
            self.hide()
        }
    }

    /// Showing, and not on its way out.
    var isVisible: Bool { (panel?.isVisible ?? false) && !slidingOut }

    private var corner: ScreenCorner { settings.anchorCorner }
    /// +1 when the shelf slides off to the right, −1 for a left-hand corner.
    private var awayDirection: CGFloat { corner.isLeft ? -1 : 1 }

    // MARK: - Showing and hiding

    func show(allowEmpty: Bool = false) {
        if allowEmpty { self.allowEmpty = true }
        guard !store.allItems.isEmpty || self.allowEmpty else { return }
        let panel = self.panel ?? makePanel()

        if isVisible {
            layout(animated: true)
            return
        }

        // Coming back while still sliding away: reverse from where it is now.
        let reversing = slidingOut
        if reversing {
            slideGeneration += 1
            slidingOut = false
        }
        store.hovering = false
        let target = targetFrame(for: panel)
        layoutGeneration += 1
        frameModel.corner = corner
        frameModel.size = target.size
        if !reversing {
            panel.setFrame(target.offsetBy(dx: awayDirection * (target.width + 40), dy: 0), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Slides the shelf away without saving anything; the screenshots stay on it.
    func hide() {
        guard let panel, isVisible else { return }
        allowEmpty = false
        slideOut(panel) { [weak self] stillHidden in
            guard stillHidden, let self else { return }
            self.store.expanded = false
            self.store.hovering = false
            self.store.clearSelection()
        }
    }

    func toggle() {
        isVisible ? hide() : show(allowEmpty: true)
    }

    /// Closes the shelf and saves or trashes everything on it, per Settings.
    /// Only what was on the shelf when you closed it: a screenshot that arrives
    /// while the shelf slides away stays.
    func dismiss() {
        allowEmpty = false
        let leaving = store.items
        guard let panel, isVisible else {
            store.dispose(leaving, action: settings.closeShelfAction)
            return
        }
        slideOut(panel) { [weak self] _ in
            guard let self else { return }
            self.store.hovering = false
            self.store.dispose(leaving, action: self.settings.closeShelfAction)
            // Anything new, or anything that could not be moved, comes back into view.
            if !self.store.isEmpty { self.show() }
        }
    }

    private var slideGeneration = 0

    /// `completion` gets false when the shelf was brought back mid-slide.
    private func slideOut(_ panel: NSPanel, completion: @escaping (_ stillHidden: Bool) -> Void) {
        slideGeneration += 1
        let generation = slideGeneration
        slidingOut = true
        let away = panel.frame.offsetBy(dx: awayDirection * (panel.frame.width + 60), dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(away, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            let current = generation == self.slideGeneration
            if current {
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.slidingOut = false
            }
            completion(current)
        })
    }

    // MARK: - Swiping away

    /// Measured in screen coordinates: the panel moves along with the pointer,
    /// so a distance inside the window would stay at zero.
    /// Positive means towards the nearest screen edge.
    private var dragDistance: CGFloat {
        guard let start = dragStartMouse else { return 0 }
        return (pointerLocation().x - start.x) * awayDirection
    }

    func dragChanged() {
        guard let panel else { return }
        if dragOrigin == nil {
            dragOrigin = panel.frame.origin
            dragStartMouse = pointerLocation()
        }
        guard let base = dragOrigin else { return }
        let offset = max(0, dragDistance)
        panel.setFrameOrigin(NSPoint(x: base.x + offset * awayDirection, y: base.y))
        panel.alphaValue = 1 - min(0.7, offset / 180)
    }

    func dragEnded() {
        let base = dragOrigin
        let distance = dragDistance
        dragOrigin = nil
        dragStartMouse = nil
        if distance > 70 {
            dismiss()
            return
        }
        guard let panel, let base else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(base)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Internals

    private func makePanel() -> ShelfPanelWindow {
        let panel = ShelfPanelWindow(
            contentRect: NSRect(origin: .zero, size: ShelfLayout.collapsed),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = ShelfView(
            store: store,
            settings: settings,
            onDismiss: { [weak self] in self?.dismiss() },
            onSettings: { [weak self] in self?.onOpenSettings() },
            onSaveShelf: { [weak self] shelf in self?.onSaveShelf(shelf) },
            onOpenShelf: { [weak self] in self?.onOpenShelf() },
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragEnded: { [weak self] in self?.dragEnded() })
        let hosting = NSHostingView(rootView: ShelfRoot(frame: frameModel, shelf: root))
        hosting.frame = NSRect(origin: .zero, size: ShelfLayout.collapsed)
        let dropView = ShelfDropView(store: store, content: hosting)
        dropView.onDropAccepted = { [weak self] in self?.droppedDuringReveal = true }
        panel.contentView = dropView

        self.panel = panel
        return panel
    }

    /// Anchored to the chosen corner; the shelf grows away from it.
    private func targetFrame(for panel: NSPanel) -> NSRect {
        let size = ShelfLayout.size(expanded: store.expanded, groups: store.groups)
        let area = anchorScreen(for: panel).visibleFrame
        return NSRect(
            x: corner.isLeft ? area.minX + margin : area.maxX - size.width - margin,
            y: corner.isTop ? area.maxY - size.height - margin : area.minY + margin,
            width: size.width,
            height: size.height)
    }

    private func anchorScreen(for panel: NSPanel) -> NSScreen {
        if panel.isVisible, let screen = panel.screen { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout(animated: Bool) {
        guard let panel, panel.isVisible, dragOrigin == nil, !slidingOut else { return }
        if !store.allItems.isEmpty { allowEmpty = false }
        if store.allItems.isEmpty && !allowEmpty {
            panel.orderOut(nil)
            store.hovering = false
            return
        }
        let target = targetFrame(for: panel)
        frameModel.corner = corner
        guard target != panel.frame || frameModel.size != target.size else { return }
        layoutGeneration += 1
        let generation = layoutGeneration

        guard animated else {
            panel.setFrame(target, display: true)
            frameModel.size = target.size
            panel.invalidateShadow()
            return
        }

        // 1. Make the window big enough for both sizes, instantly. The visible
        //    shelf is pinned to the corner, so nothing on screen moves.
        let room = panel.frame.union(target)
        if room != panel.frame { resize(panel, to: room) }
        // 2. Let SwiftUI grow or shrink the shelf, in step with the screenshots.
        withAnimation(.easeOut(duration: Self.resizeDuration)) { frameModel.size = target.size }
        followShadow(for: Self.resizeDuration + 0.06)
        // 3. Once it has settled, trim the window back to the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDuration + 0.04) { [weak self] in
            guard let self, generation == self.layoutGeneration,
                  self.dragOrigin == nil, !self.slidingOut, panel.isVisible else { return }
            self.resize(panel, to: self.targetFrame(for: panel))
            panel.invalidateShadow()
        }
    }

    /// Resizes the window without a single frame where the shelf sits in the
    /// wrong spot: SwiftUI would otherwise draw once at the old position before
    /// catching up with the corner it's pinned to.
    private func resize(_ panel: NSPanel, to frame: NSRect) {
        panel.disableScreenUpdatesUntilFlush()
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    static let resizeDuration: TimeInterval = 0.24

    /// The window shadow is traced from what's drawn, so refresh it while the
    /// shelf changes size.
    private func followShadow(for seconds: TimeInterval) {
        shadowTimer?.invalidate()
        let end = Date().addingTimeInterval(seconds)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            self?.panel?.invalidateShadow()
            if Date() >= end { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        shadowTimer = timer
    }
}
