import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Fixtures.isolateStorage()
let settings = AppSettings.shared
// Deliberately leaving the hot corner off: switching it on installs real event
// monitors, which would count the user's own scrolling.
settings.hotCorner = nil

let triggers = ToggleTriggers.shared
var shows = 0, hides = 0, toggles = 0
triggers.onShow = { shows += 1 }
triggers.onHide = { hides += 1 }
triggers.onToggle = { toggles += 1 }

let screen = NSScreen.screens[0].frame
let inCorner = NSPoint(x: screen.maxX - 5, y: screen.minY + 5)
let nearEdge = NSPoint(x: screen.maxX - 205, y: screen.minY + 205)
let justOutside = NSPoint(x: screen.maxX - 100, y: screen.minY + 215)
let elsewhere = NSPoint(x: screen.midX, y: screen.midY)

func scroll(horizontal: Int32 = 0, vertical: Int32 = 0, precise: Bool = false) -> NSEvent {
    NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                             wheel1: vertical, wheel2: horizontal, wheel3: 0)!)!
}
let left = scroll(horizontal: 1), right = scroll(horizontal: -1)
let up = scroll(vertical: 1), down = scroll(vertical: -1)

Check.section("Scrolling in the corner")
triggers.pointerLocation = { elsewhere }
for _ in 0..<5 { triggers.handleCornerScroll(left, corner: .bottomRight); triggers.handleCornerScroll(right, corner: .bottomRight) }
Check.ok(shows == 0 && hides == 0, "scrolling sideways elsewhere does nothing")
triggers.pointerLocation = { inCorner }
triggers.handleCornerScroll(left, corner: .bottomRight)
Check.ok(shows == 1, "in the corner, scrolling left shows the shelf")
spin(0.6)
triggers.handleCornerScroll(right, corner: .bottomRight)
Check.ok(hides == 1, "scrolling right hides it")
triggers.handleCornerScroll(right, corner: .bottomRight)
Check.ok(hides == 1, "a burst of wheel ticks only counts once")
spin(0.6)
triggers.pointerLocation = { nearEdge }
triggers.handleCornerScroll(left, corner: .bottomRight)
Check.ok(shows == 2, "205 × 205 from the corner still counts")
spin(0.6)
triggers.pointerLocation = { justOutside }
triggers.handleCornerScroll(left, corner: .bottomRight)
Check.ok(shows == 2, "just outside the 210 × 210 area it doesn't")

Check.section("Which way")
triggers.pointerLocation = { inCorner }
spin(0.6)
settings.swapScrollDirections = true
triggers.handleCornerScroll(left, corner: .bottomRight)
Check.ok(hides == 2, "Swap directions: left hides")
settings.swapScrollDirections = false
spin(0.6)
settings.swipeAxis = .vertical
triggers.handleCornerScroll(up, corner: .bottomRight)
Check.ok(shows == 3, "up and down: up shows")
spin(0.6)
triggers.handleCornerScroll(down, corner: .bottomRight)
Check.ok(hides == 3, "down hides")
spin(0.6)
triggers.handleCornerScroll(left, corner: .bottomRight)
Check.ok(shows == 3 && hides == 3, "sideways is ignored in that mode")
settings.swipeAxis = .both
spin(0.6)
triggers.handleCornerScroll(left, corner: .bottomRight)
spin(0.6)
triggers.handleCornerScroll(down, corner: .bottomRight)
Check.ok(shows == 4 && hides == 4, "either mode takes both")
settings.swipeAxis = .horizontal
spin(0.6)
for _ in 0..<2 { triggers.handleCornerScroll(scroll(horizontal: 10, precise: true), corner: .bottomRight) }
Check.ok(shows == 4, "a small trackpad nudge isn't enough")
for _ in 0..<2 { triggers.handleCornerScroll(scroll(horizontal: 10, precise: true), corner: .bottomRight) }
Check.ok(shows == 5, "a real swipe is")
Check.ok(toggles == 0, "corner scrolling only shows or hides, never toggles")

Check.section("Hover doesn't stick")
// A window right under the pointer, so the view really is hovered, then moved
// away without macOS sending an exit: the shelf resizing under a still pointer.
let warmUp = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10),
                      styleMask: [.borderless], backing: .buffered, defer: false)
warmUp.orderFrontRegardless(); spin(0.5); warmUp.orderOut(nil)
let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
func hoverCase(_ name: String, _ make: () -> (NSView, () -> Bool, () -> Void)) {
    // This needs the real pointer to sit on the view, so if it moves mid-test
    // (someone is using the Mac) try again rather than call it a failure.
    for attempt in 1...3 {
        let pointer = NSEvent.mouseLocation
        let window = NSWindow(contentRect: NSRect(x: pointer.x - 11, y: pointer.y - 11, width: 22, height: 22),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let (view, hovered, enter) = make()
        view.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        window.contentView = view
        window.orderFrontRegardless()
        spin(0.35)
        enter()
        spin(0.1)
        guard hovered() else {
            window.orderOut(nil)
            if attempt == 3 { print("  – \(name): skipped, the pointer kept moving") }
            continue
        }
        Check.ok(true, "\(name): hovered while the pointer is on it")
        // The shelf moving out from under a pointer that stands still: no exit event.
        window.setFrameOrigin(NSPoint(x: pointer.x + 400, y: pointer.y + 400))
        spin(0.5)
        Check.ok(!hovered(), "\(name): clears itself once the pointer isn't there")
        window.orderOut(nil)
        return
    }
}

hoverCase("shelf icon") {
    let dot = ShelfDotView(frame: .zero)
    var hovered = false
    dot.onHover = { hovered = $0 }
    return (dot, { hovered }, { dot.mouseEntered(with: entered) })
}
hoverCase("screenshot") {
    let tile = DragOutNSView(frame: .zero)
    var hovered = false
    tile.onHover = { hovered = $0 }
    return (tile, { hovered }, { tile.mouseEntered(with: entered) })
}

Fixtures.cleanUp()
Check.finish()
