import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Fixtures.isolateStorage()
AppSettings.shared.closeShelfAction = .save
AppSettings.shared.thumbnailSize = .small

let controller = ShelfController()
let store = controller.store
var pointer = NSPoint(x: 500, y: 500)
controller.pointerLocation = { pointer }
var panel: NSWindow { NSApp.windows.first { $0 is ShelfPanelWindow }! }
func glassOnScreen() -> NSRect? {
    var found: NSRect?
    func walk(_ view: NSView) {
        if found == nil, view is NSVisualEffectView, let window = view.window {
            found = window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        view.subviews.forEach(walk)
    }
    if let content = panel.contentView { walk(content) }
    return found
}

Check.section("Swiping the shelf away")
store.currentIndex = 1
store.add(Fixtures.image(hue: 0.2))
controller.show()
spin(0.8)
let home = panel.frame.minX
pointer = NSPoint(x: 500, y: 500)
for _ in 1...10 {
    controller.dragChanged()
    pointer.x += 12
    spin(0.01)
}
controller.dragChanged()
let released = panel.frame.minX
store.hovering = true; store.hovering = false // something changes just as you let go
controller.dragEnded()
var positions = [released]
for _ in 0..<35 { spin(0.01); positions.append(panel.frame.minX) }
let backwards = zip(positions, positions.dropFirst()).filter { $1 - $0 < -0.5 }.count
Check.ok(released > home + 100, "the shelf follows the pointer")
Check.ok(backwards == 0, "and never jumps back left on release (\(backwards) steps)")
spin(0.4)
Check.ok(!controller.isVisible && store.isEmpty, "it's gone, and the screenshot was saved")

Check.section("Empty shelves stay reachable")
store.shelves = ShelfStore.defaultShelves()
store.currentIndex = 0
store.add(Fixtures.image(hue: 0.4))          // on Starred
store.currentIndex = 1
store.add(Fixtures.image(hue: 0.6))          // on Shelf 1
store.expanded = true
controller.show()
spin(0.8)
store.dispose(store.items, action: .trash)
let trashed = store.allItems.map(\.url.lastPathComponent)
spin(0.6)
Check.ok(controller.isVisible && store.expanded, "emptying the shelf you're on keeps it open")
store.select(2)
spin(0.6)
Check.ok(controller.isVisible && store.currentIndex == 2 && store.isEmpty, "an unused shelf opens empty, in reach")
store.select(0)
spin(0.6)
Check.ok(controller.isVisible && store.items.count == 1, "and back to Starred with its screenshot")
store.disposeEverywhere(store.allItems, action: .trash)
spin(0.9)
Check.ok(!controller.isVisible, "only when every shelf is empty does it go away")
Fixtures.emptyTrashOf(trashed + store.allItems.map(\.url.lastPathComponent))

Check.section("Resizing between shelves of different heights")
store.shelves = ShelfStore.defaultShelves()
store.currentIndex = 1
store.add(Fixtures.image(hue: 0.1))                       // one row
store.currentIndex = 2
for hue in [0.2, 0.4, 0.6, 0.8] { store.add(Fixtures.image(hue: hue)) }   // two rows
store.currentIndex = 1
store.expanded = true
controller.show()
spin(0.9)
func sample(switchingTo index: Int) -> [NSRect] {
    store.select(index)
    var samples: [NSRect] = []
    for _ in 0..<45 { spin(0.01); if let rect = glassOnScreen() { samples.append(rect) } }
    return samples
}
for (label, index) in [("growing", 2), ("shrinking", 1)] {
    let samples = sample(switchingTo: index)
    let tops = samples.map(\.maxY)
    let steps = zip(tops, tops.dropFirst()).map { $1 - $0 }
    let grows = (tops.last ?? 0) > (tops.first ?? 0)
    let wrongWay = steps.filter { grows ? $0 < -0.5 : $0 > 0.5 }.count
    let total = abs((tops.last ?? 0) - (tops.first ?? 0))
    Check.ok((samples.map(\.minY).max()! - samples.map(\.minY).min()!) < 0.5, "\(label): the corner stays put")
    Check.ok(wrongWay == 0, "\(label): the edge never moves the wrong way")
    Check.ok(total > 50 && steps.map(abs).max()! < total * 0.6,
             "\(label): in steps, not one jump (biggest \(Int(steps.map(abs).max()!)) of \(Int(total)) pt)")
    spin(0.3)
    let settled = glassOnScreen()!
    Check.ok(abs(panel.frame.height - settled.height) < 0.5, "\(label): the window ends up fitting the shelf")
}

Check.section("Grouped by date, newest first")
store.shelves = [Shelf(name: "Shelf 1")]
store.currentIndex = 0
let calendar = Calendar.current
for days in [0, 1, 9, 40] {
    store.add(Fixtures.image(hue: 0.5, date: calendar.date(byAdding: .day, value: -days, to: Date())!))
}
let titles = store.groups.map(\.title)
Check.ok(titles.first == "Today" && titles.contains("Yesterday") && titles.contains("Last week"),
         "Today, Yesterday, Last week, … (\(titles))")
Check.ok(ShelfGroup.title(for: calendar.date(byAdding: .day, value: -3, to: Date())!) == "Earlier this week",
         "three days ago reads as earlier this week")
store.disposeEverywhere(store.allItems, action: .trash)
Fixtures.emptyTrashOf(store.allItems.map(\.url.lastPathComponent))

Fixtures.cleanUp()
Check.finish()
