import AppKit
import Combine
import SwiftUI

/// A floating panel that never steals focus from the app you are working in.
final class ShelfPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows, positions, hides and swipes away the shelf.
final class ShelfController {
    let store = ShelfStore()
    var onOpenSettings: () -> Void = {}
    var onSaveShelf: (Shelf) -> Void = { _ in }
    var onOpenShelf: () -> Void = {}

    private let settings = AppSettings.shared
    private var panel: ShelfPanelWindow?
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

        // Switching to an empty shelf must not make the shelf vanish. This runs
        // straight away, before the layout pass that would otherwise hide it.
        store.$currentIndex
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.allowEmpty = true
            }
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
        guard !store.isEmpty || self.allowEmpty else { return }
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
        let hosting = NSHostingView(rootView: root)
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
        if !store.isEmpty { allowEmpty = false }
        if store.isEmpty && !allowEmpty {
            panel.orderOut(nil)
            store.hovering = false
            return
        }
        let target = targetFrame(for: panel)
        guard target != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }
}
