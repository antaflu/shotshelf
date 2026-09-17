import AppKit
import Carbon.HIToolbox
import Combine

/// A system-wide hotkey via Carbon. Needs no Accessibility permission.
final class GlobalHotKey {
    private static var counter: UInt32 = 0
    private let id: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        GlobalHotKey.counter += 1
        id = GlobalHotKey.counter
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5353_4846), id: id) // 'SSHF'
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            NSLog("ShotShelf: shortcut already taken by another app (%d)", registered)
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Every way to show or hide the shelf: a keyboard shortcut, an extra mouse
/// button, and a hot corner (move the pointer in, or scroll sideways there, as
/// with the thumb wheel on a Logitech mouse).
final class ToggleTriggers {
    static let shared = ToggleTriggers()

    var onToggle: () -> Void = {}

    private let settings = AppSettings.shared
    private var hotKey: GlobalHotKey?
    private var monitors: [Any] = []
    private var cornerTimer: Timer?
    private var cornerArmed = true
    private var scrollAccumulated: CGFloat = 0
    private var lastFired = Date.distantPast
    private var suspended = false
    private var cancellable: AnyCancellable?

    private init() {}

    func start() {
        cancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
        apply()
    }

    /// While a new shortcut is being recorded, the old one must not fire.
    func setSuspended(_ value: Bool) {
        suspended = value
        apply()
    }

    private func apply() {
        hotKey = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        cornerTimer?.invalidate()
        cornerTimer = nil
        guard !suspended else { return }

        if let shortcut = settings.toggleShortcut {
            hotKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in
                self?.fire()
            }
        }

        switch settings.toggleMouseTrigger {
        case .button(let button):
            addMonitors(for: .otherMouseDown) { [weak self] event in
                if event.buttonNumber == button { self?.fire() }
            }
        case .sidewaysScroll(let direction, let modifiers):
            addMonitors(for: .scrollWheel) { [weak self] event in
                self?.handleSidewaysScroll(event, direction: direction, modifiers: modifiers)
            }
        case nil:
            break
        }

        guard let corner = settings.hotCorner else { return }
        switch settings.hotCornerAction {
        case .enter:
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.pollCorner(corner) }
            RunLoop.main.add(timer, forMode: .common)
            cornerTimer = timer
            cornerArmed = distance(to: corner) > 40 // don't fire right away if the pointer is already there
        case .horizontalScroll:
            addMonitors(for: .scrollWheel) { [weak self] event in self?.handleScroll(event, corner: corner) }
        }
    }

    /// Global monitors miss events in our own windows, so add both.
    private func addMonitors(for mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func fire() {
        guard !suspended, Date().timeIntervalSince(lastFired) > 0.4 else { return }
        lastFired = Date()
        onToggle()
    }

    // MARK: - Sideways scroll

    private var sidewaysAccumulated: CGFloat = 0
    private var lastSidewaysEvent = Date.distantPast

    func handleSidewaysScroll(_ event: NSEvent, direction: Int, modifiers: UInt) {
        let held = event.modifierFlags.intersection(MouseTrigger.modifierMask).rawValue
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard held == modifiers, abs(dx) > abs(dy), (dx > 0 ? 1 : -1) == direction,
              event.momentumPhase.isEmpty else { return }

        // A pause means a new swipe of the wheel.
        if Date().timeIntervalSince(lastSidewaysEvent) > 0.3 { sidewaysAccumulated = 0 }
        lastSidewaysEvent = Date()
        sidewaysAccumulated += abs(dx)

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        guard sidewaysAccumulated >= threshold else { return }
        sidewaysAccumulated = 0
        if Date().timeIntervalSince(lastFired) > 0.8 { fire() }
    }

    // MARK: - Hot corner

    /// Distance from the pointer to the chosen corner of the screen it is on
    /// (the larger of the horizontal and vertical distance).
    private func distance(to corner: ScreenCorner) -> CGFloat {
        let p = NSEvent.mouseLocation
        guard let frame = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })?.frame else {
            return .greatestFiniteMagnitude
        }
        let dx = corner.isLeft ? p.x - frame.minX : frame.maxX - p.x
        let dy = corner.isTop ? frame.maxY - p.y : p.y - frame.minY
        return max(dx, dy)
    }

    private func pollCorner(_ corner: ScreenCorner) {
        let d = distance(to: corner)
        if d <= 3, cornerArmed {
            cornerArmed = false
            fire()
        } else if d > 40 {
            cornerArmed = true
        }
    }

    private func handleScroll(_ event: NSEvent, corner: ScreenCorner) {
        guard distance(to: corner) <= 80 else {
            scrollAccumulated = 0
            return
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dx) > abs(dy) else { return }
        scrollAccumulated += abs(dx)
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        if scrollAccumulated >= threshold {
            scrollAccumulated = 0
            if Date().timeIntervalSince(lastFired) > 0.8 { fire() }
        }
    }
}
