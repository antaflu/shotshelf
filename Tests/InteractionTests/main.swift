import AppKit
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Fixtures.isolateStorage()
let settings = AppSettings.shared

let store = ShelfStore()
store.shelves = [Shelf(name: "Shelf 1"), Shelf(name: "Shelf 2")]
store.currentIndex = 0
for hue in [0.1, 0.3, 0.5, 0.7] { store.add(Fixtures.image(hue: hue)) }
store.expanded = true

var shelfMoves = 0
var quickLooked: [URL] = []
store.quickLookHandler = { urls, _ in quickLooked = urls }

let size = ShelfLayout.size(expanded: true, groups: store.groups)
let panel = ShelfPanelWindow(contentRect: NSRect(x: 300, y: 300, width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let hosting = NSHostingView(rootView: ShelfView(store: store, settings: settings, onDismiss: {}, onSettings: {},
                                                onSaveShelf: { _ in }, onOpenShelf: {},
                                                onDragChanged: { shelfMoves += 1 }, onDragEnded: {}))
hosting.frame = NSRect(origin: .zero, size: size)
panel.contentView = hosting
panel.orderFrontRegardless()
spin(1.0)

func views<T: NSView>(_ type: T.Type) -> [T] {
    var found: [T] = []
    func walk(_ view: NSView) {
        if let match = view as? T { found.append(match) }
        view.subviews.forEach(walk)
    }
    walk(hosting)
    return found
}
func tiles() -> [DragOutNSView] {
    views(DragOutNSView.self).filter { $0.itemID != nil }.sorted {
        let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
        return a.midY.rounded() != b.midY.rounded() ? a.midY > b.midY : a.midX < b.midX
    }
}
func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
func middle(_ tile: NSView) -> NSPoint { NSPoint(x: rect(tile).midX, y: rect(tile).midY) }
/// Free of the hover buttons, wherever they are.
func corner(_ tile: NSView) -> NSPoint { NSPoint(x: rect(tile).maxX - 8, y: rect(tile).minY + 8) }
func send(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
    panel.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: clicks, pressure: 1)!)
}
func click(_ point: NSPoint, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
    send(.leftMouseDown, point, flags, clicks: clicks)
    send(.leftMouseUp, point, flags, clicks: clicks)
    spin(0.25)
}
func sweep(_ points: [NSPoint], holdFirst: Double = 0, flags: NSEvent.ModifierFlags = []) {
    send(.leftMouseDown, points[0], flags)
    if holdFirst > 0 { spin(holdFirst) }
    for (from, to) in zip(points, points.dropFirst()) {
        for step in 1...8 {
            let f = CGFloat(step) / 8
            send(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), flags)
            spin(0.02)
        }
    }
    send(.leftMouseUp, points.last!, flags)
    spin(0.3)
}
func hover(_ tile: DragOutNSView) {
    tiles().forEach { $0.onHover(false) }
    tile.onHover(true)
    spin(0.35)
}

var t = tiles()
let ids = t.map { $0.itemID! }
Check.ok(t.count == 4, "four screenshots on the shelf")

Check.section("Clicking selects")
click(middle(t[1]))
Check.ok(store.selection == [ids[1]], "a click selects that screenshot")
click(corner(t[2]), .command)
Check.ok(store.selection == [ids[1], ids[2]], "⌘-click adds to the selection")
click(corner(t[0]), .shift)
Check.ok(store.selection.count >= 2, "⇧-click selects a range")
click(middle(t[3]))
Check.ok(store.selection == [ids[3]], "a plain click starts over")

Check.section("Double-click opens Quick Look")
send(.leftMouseDown, middle(t[0])); send(.leftMouseUp, middle(t[0]))
send(.leftMouseDown, middle(t[0]), clicks: 2); send(.leftMouseUp, middle(t[0]), clicks: 2)
spin(0.3)
Check.ok(quickLooked == [store.items.first { $0.id == ids[0] }!.url], "it previews that screenshot")

Check.section("Hover buttons")
store.clearSelection(); spin(0.2)
t = tiles()
hover(t[0])
Check.ok(t[0].hotspots(t[0].bounds.size).map(\.id) == ["close"], "by default only the × appears")
settings.hoverQuickActions = true
spin(0.3)
t = tiles(); hover(t[0])
let spots = t[0].hotspots(t[0].bounds.size)
func spot(at point: NSPoint) -> String? {
    let local = t[0].convert(point, from: nil)
    return spots.first { $0.rect.contains(local) }?.id
}
let copyPoint = NSPoint(x: rect(t[0]).midX, y: rect(t[0]).midY + 13)
let viewPoint = NSPoint(x: rect(t[0]).midX, y: rect(t[0]).midY - 13)
Check.ok(spot(at: copyPoint) == "copy" && spot(at: viewPoint) == "view", "Copy above View, in the middle")
Check.ok(spot(at: NSPoint(x: rect(t[0]).minX + 14, y: rect(t[0]).minY + 14)) == "delete", "Delete bottom-left")
Check.ok(spot(at: NSPoint(x: rect(t[0]).maxX - 11, y: rect(t[0]).maxY - 11)) == "close", "× top-right")
Check.ok(panel.contentView?.hitTest(copyPoint) is DragOutNSView, "a drag can still start on the Copy button")
NSPasteboard.general.clearContents()
click(copyPoint)
Check.ok((NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.count == 1, "Copy copies")
quickLooked = []
click(viewPoint)
Check.ok(quickLooked.count == 1, "View opens Quick Look")
settings.hoverQuickActions = false
spin(0.3)

Check.section("Right-click menu")
t = tiles()
let event = NSEvent.mouseEvent(with: .rightMouseDown, location: middle(t[0]), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
let titles = t[0].menu(for: event)?.items.map(\.title) ?? []
Check.ok(titles.contains("Copy") && titles.contains("Quick Look") && titles.contains("Delete"),
         "copy, Quick Look and delete (\(titles.filter { !$0.isEmpty }))")
Check.ok(!titles.contains("Open in Preview"), "no Preview any more")
let shelfMenu = t[0].menu(for: event)?.items.first { $0.title == "Move to Shelf" }?.submenu?.items.map(\.title) ?? []
Check.ok(shelfMenu == ["Shelf 2", "New Shelf"], "and moving to the other shelf (\(shelfMenu))")
let pasteMenu = views(SelectionCanvasNSView.self).first?.menu(for: event)?.items.map(\.title) ?? []
Check.ok(pasteMenu == ["Paste"], "right-clicking empty space offers Paste")

Check.section("Selection rectangle and swiping")
t = tiles()
let gap = NSPoint(x: (rect(t[0]).maxX + rect(t[1]).minX) / 2, y: rect(t[0]).midY)
sweep([gap, middle(t[2])])
Check.ok(store.selection == Set([ids[1], ids[2]]), "a rectangle from the gap selects what it touches")
shelfMoves = 0
sweep([NSPoint(x: 6, y: rect(t[0]).midY), NSPoint(x: 86, y: rect(t[0]).midY)])
Check.ok(shelfMoves > 0, "dragging the border swipes the shelf away (\(shelfMoves) moves)")
shelfMoves = 0
sweep([NSPoint(x: size.width / 2, y: 10), NSPoint(x: size.width / 2 + 80, y: 10)])
Check.ok(shelfMoves > 0, "so does the strip along the bottom")

Check.section("Header")
let headerY = rect(t[0]).maxY + ShelfLayout.gap + ShelfLayout.headerHeight / 2
let dots = views(ShelfDotView.self).map { rect($0) }.sorted { $0.minX < $1.minX }
Check.ok(dots.count == store.shelves.count, "an icon per shelf, at the right")
shelfMoves = 0
sweep([NSPoint(x: ShelfLayout.pad + 60, y: headerY), NSPoint(x: ShelfLayout.pad + 140, y: headerY)])
Check.ok(shelfMoves > 0, "swiping the header moves the shelf too")
click(NSPoint(x: dots[1].midX, y: dots[1].midY))
Check.ok(store.currentIndex == 1 && store.expanded, "clicking a shelf icon switches shelves")
click(NSPoint(x: dots[0].midX, y: dots[0].midY))
Check.ok(store.currentIndex == 0, "and back")
click(NSPoint(x: ShelfLayout.pad + 60, y: headerY))
spin(0.5)
Check.ok(!store.expanded, "clicking the header collapses the shelf")

panel.orderOut(nil)
Fixtures.cleanUp()
Check.finish()
