import AppKit
import Carbon.HIToolbox

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Fixtures.isolateStorage()

let store = ShelfStore()
store.select(1)
for hue in [0.1, 0.3, 0.5, 0.7] { store.add(Fixtures.image(hue: hue)) }
store.expanded = true
let order = store.displayOrder
var previewed: [URL] = []
var toggled = false
store.quickLookHandler = { urls, toggle in previewed = urls; toggled = toggle }
let keyboard = ShelfKeyboard(store: store)

func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "x") -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: UInt16(code))!
}

Check.section("Selecting like Finder")
store.selectOnly(order[0])
Check.ok(store.selection == [order[0].id], "a click selects just that one")
store.toggleSelection(order[1])
Check.ok(store.selection == [order[0].id, order[1].id], "⌘-click adds")
store.selectOnly(order[0])
store.selectRange(to: order[2])
Check.ok(store.selection == Set(order[0...2].map(\.id)), "⇧-click selects a range")

Check.section("Keys")
store.selectOnly(order[0])
Check.ok(keyboard.handle(key(kVK_Space, [], " ")) && previewed == [order[0].url] && toggled,
         "space opens Quick Look for the selection")
NSPasteboard.general.clearContents()
Check.ok(keyboard.handle(key(kVK_ANSI_C, .command, "c")) &&
         (NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.count == 1,
         "⌘C copies")
Check.ok(store.justCopied == [order[0].id], "with a brief Copied badge")
Check.ok(keyboard.handle(key(kVK_ANSI_A, .command, "a")) && store.selection.count == store.items.count,
         "⌘A selects all")
Check.ok(keyboard.handle(key(kVK_Escape, [], "\u{1b}")) && store.selection.isEmpty, "Escape deselects")
Check.ok(!keyboard.handle(key(kVK_Space, [], " ")), "space with nothing selected is passed on")
store.selectOnly(order[1])
Check.ok(keyboard.handle(key(kVK_RightArrow)) && store.selection == [order[2].id], "→ steps to the next one")
Check.ok(keyboard.handle(key(kVK_LeftArrow)) && store.selection == [order[1].id], "← steps back")
let doomed = store.selectedItems[0]
Check.ok(keyboard.handle(key(kVK_Delete, .command)) && !store.allItems.contains { $0.id == doomed.id },
         "⌘⌫ moves it to the Trash")
Fixtures.emptyTrashOf([doomed.url.lastPathComponent])
Check.ok(!keyboard.handle(key(kVK_ANSI_X, [], "x")), "other keys are left alone")
store.expanded = false
store.selectOnly(store.items[0])
Check.ok(!keyboard.handle(key(kVK_Space, [], " ")), "and nothing happens while the shelf is collapsed")
store.expanded = true

Check.section("Quick Look, not Preview")
previewed = []
store.quickLook([store.items[0]])
Check.ok(previewed == [store.items[0].url] && !toggled, "the View button and double-click open Quick Look")
store.quickLookHandler = { urls, toggle in
    toggle ? ShelfQuickLook.shared.toggle(urls) : ShelfQuickLook.shared.show(urls)
}
store.quickLook([store.items[0]])
spin(0.8)
Check.ok(ShelfQuickLook.shared.isOpen, "the real Quick Look panel opens")
ShelfQuickLook.shared.toggle([])
spin(0.5)
Check.ok(!ShelfQuickLook.shared.isOpen, "and space closes it")

Check.section("The shelf takes the keys without activating the app")
let panel = ShelfPanelWindow(contentRect: NSRect(x: -3000, y: -3000, width: 100, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
var seen: [UInt16] = []
panel.keyHandler = { seen.append($0.keyCode); return true }
panel.orderFrontRegardless()
panel.makeKey()
spin(0.2)
panel.sendEvent(key(kVK_Space, [], " "))
Check.ok(seen == [UInt16(kVK_Space)], "a key reaches the shelf's handler")
Check.ok(panel.canBecomeKey && !panel.canBecomeMain && DragOutNSView(frame: .zero).needsPanelToBecomeKey,
         "clicking a screenshot hands over the keyboard")
panel.orderOut(nil)

Fixtures.cleanUp()
Check.finish()
