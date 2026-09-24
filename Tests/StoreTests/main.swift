import AppKit

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared
Fixtures.isolateStorage()

let store = ShelfStore()

Check.section("Shelves")
Check.ok(store.shelves.map(\.name) == ["Starred", "Shelf 1", "Shelf 2"], "Starred, Shelf 1, Shelf 2 to start with")
Check.ok(store.currentIndex == 1 && store.shelves[0].isStarredShelf, "you start on Shelf 1; Starred knows its role")
store.addShelf()
Check.ok(store.shelves.last?.name == "Shelf 3", "a new shelf is Shelf 3: Starred doesn't count")
store.removeShelf(at: 1)
Check.ok(store.shelves.map(\.name) == ["Starred", "Shelf 1", "Shelf 2"], "removing renumbers the automatic names")
store.shelves[2].name = "Work"
store.moveShelf(from: 2, to: 1)
Check.ok(store.shelves.map(\.name) == ["Starred", "Work", "Shelf 1"], "your own names survive reordering")
store.shelves[1].name = "Shelf 1"
store.shelves[2].name = "Shelf 2"
store.removeShelf(at: 0)
Check.ok(store.starredShelfIndex == 0, "Starred can't be removed")

Check.section("Screenshots go to the shelf you have open")
store.select(1)
store.add(Fixtures.image(hue: 0.1))
store.add(Fixtures.image(hue: 0.3))
store.add(Fixtures.image(hue: 0.5))
Check.ok(store.items.count == 3 && store.shelves[2].items.isEmpty, "they land on Shelf 1")
let (a, b) = (store.items[0], store.items[1])

Check.section("Starring collects instead of moving")
store.setStarred([a], true)
Check.ok(store.shelves[1].items.count == 3, "the screenshot stays on its own shelf")
Check.ok(store.displayedItems(at: 0).map(\.id) == [a.id], "and shows on Starred as well")
Check.ok(store.allItems.count == 3, "it isn't copied")
store.move([b], toShelf: 0)
Check.ok(store.shelves[1].items.contains { $0.id == b.id } && store.displayedItems(at: 0).count == 2,
         "dropping onto Starred stars it, rather than moving it")
store.setStarred([a], false)
Check.ok(store.displayedItems(at: 0).map(\.id) == [b.id] && store.shelves[1].items.count == 3,
         "unstarring only takes it off Starred")
store.select(0)
store.add(Fixtures.image(hue: 0.8))
let own = store.shelves[0].items[0]
Check.ok(own.isStarred, "adding while Starred is open puts it there, starred")
store.setStarred([own], false)
Check.ok(store.shelves[0].items.isEmpty && store.shelves[1].items.contains { $0.id == own.id },
         "unstarring that one gives it a home instead of losing it")

Check.section("Moving between shelves")
store.select(1)
store.move([a], toShelf: 2)
Check.ok(store.shelves[2].items.map(\.id) == [a.id] && !store.shelves[1].items.contains { $0.id == a.id },
         "it really moves")

Check.section("Getting rid of screenshots")
let saved = AppSettings.shared.saveFolder
store.select(2)
store.dispose(store.items, action: .save)
Check.ok(store.shelves[2].items.isEmpty &&
         (try? FileManager.default.contentsOfDirectory(atPath: saved.path))?.count == 1,
         "saving moves the file to the save folder")
store.select(1)
let doomed = store.items[0]
store.dispose([doomed], action: .trash)
Check.ok(!store.allItems.contains { $0.id == doomed.id }, "trashing takes it off every shelf")
Fixtures.emptyTrashOf([doomed.url.lastPathComponent])

Check.section("Dropping and pasting")
let onDisk = Fixtures.image(hue: 0.2, named: "on-disk.png")
let board = NSPasteboard.withUniqueName()
board.clearContents()
board.writeObjects([onDisk as NSURL])
Check.ok(ShelfDropHandler.canAccept(board) && ShelfDropHandler.accept(board, into: store), "an image file is accepted")
Check.ok(store.items.last?.isReference == true, "a file from disk is only referenced")
store.dispose([store.items.last!], action: .trash)
Check.ok(FileManager.default.fileExists(atPath: onDisk.path), "so deleting it leaves the original alone")
let text = Fixtures.folder.appendingPathComponent("notes.txt")
try! "hello".write(to: text, atomically: true, encoding: .utf8)
let textBoard = NSPasteboard.withUniqueName()
textBoard.clearContents()
textBoard.writeObjects([text as NSURL])
Check.ok(!ShelfDropHandler.canAccept(textBoard), "a text file is refused")

Check.section("Shelves survive a restart")
store.select(1)
store.setStarred([store.items[0]], true)
store.shelves[1].symbol = .emoji("🚀")
ShelfStorage.save(store)
let reopened = ShelfStore()
ShelfStorage.load(into: reopened)
Check.ok(reopened.shelves.map(\.name) == store.shelves.map(\.name), "the shelves come back")
Check.ok(reopened.shelves[1].symbol == .emoji("🚀"), "with their icons")
Check.ok(reopened.starredShelfIndex == 0 && reopened.displayedItems(at: 0).count == 1, "and the stars")

Check.section("A .shelf file")
let file = Fixtures.folder.appendingPathComponent("My shelf.shelf")
try! ShelfStorage.export(reopened.shelves[1], to: file)
let imported = try! ShelfStorage.importShelf(from: file)
Check.ok(imported.items.count == reopened.shelves[1].items.count && imported.symbol == .emoji("🚀"),
         "saves and opens again, icon included")
Check.ok(imported.items.allSatisfy { $0.url.path.hasPrefix(ShelfStorage.importedURL.path) },
         "with its own copies of the images")

Fixtures.cleanUp()
Check.finish()
