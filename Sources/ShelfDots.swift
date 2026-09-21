import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets a menu item run a closure, and keeps that closure alive with the item.
final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire() { run() }
}

extension NSMenu {
    @discardableResult
    func addAction(_ title: String, enabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = addItem(withTitle: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action // retains the closure
        item.isEnabled = enabled
        return item
    }
}

/// The shelf icons in the header. Click one to switch shelves, drag screenshots
/// onto one to move them there, drag the icons themselves to reorder, and
/// right-click for a shelf's own menu.
struct ShelfDots: View {
    @ObservedObject var store: ShelfStore
    var onSave: (Shelf) -> Void
    var onOpen: () -> Void

    /// Marks a drag as "a shelf is being reordered" rather than a screenshot.
    static let reorderPrefix = "shotshelf-shelf:"

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(store.shelves.enumerated()), id: \.element.id) { index, shelf in
                ShelfDot(shelf: shelf, index: index, store: store, onSave: onSave, onOpen: onOpen)
            }
        }
    }
}

/// A shelf's icon in the header. Everything with a mouse in it is AppKit: a
/// SwiftUI drop target inside this floating panel isn't reliable, and this is
/// the same approach the screenshots themselves use.
final class ShelfDotView: NSView, NSDraggingSource {
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onTargeted: (Bool) -> Void = { _ in }
    var onDropItems: ([URL]) -> Void = { _ in }
    var onReorder: (UUID) -> Void = { _ in }
    var menuProvider: (() -> NSMenu?)?
    var shelfID = UUID()
    var dragImage: NSImage?

    private var mouseDownAt: NSPoint = .zero
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(NSEvent.pressedMouseButtons == 0) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        mouseDownAt = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let dx = event.locationInWindow.x - mouseDownAt.x
        let dy = event.locationInWindow.y - mouseDownAt.y
        guard abs(dx) > 3 || abs(dy) > 3 else { return }
        dragging = true

        // Dragging the icon itself reorders the shelves.
        let item = NSPasteboardItem()
        item.setString("\(ShelfDots.reorderPrefix)\(shelfID.uuidString)", forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: dragImage ?? snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick() }
        dragging = false
    }

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // MARK: - Taking a drop

    private func payload(_ info: NSDraggingInfo) -> (reorder: UUID?, urls: [URL]) {
        let pasteboard = info.draggingPasteboard
        if let text = pasteboard.string(forType: .string), text.hasPrefix(ShelfDots.reorderPrefix) {
            return (UUID(uuidString: String(text.dropFirst(ShelfDots.reorderPrefix.count))), [])
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (nil, urls)
    }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let content = payload(info)
        if let id = content.reorder { return id == shelfID ? [] : .move }
        // The screenshots offer .copy, and an operation the source doesn't
        // offer is silently refused.
        return content.urls.isEmpty ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = operation(for: sender)
        onTargeted(!allowed.isEmpty)
        return allowed
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        let content = payload(sender)
        if let id = content.reorder, id != shelfID {
            onReorder(id)
            return true
        }
        guard !content.urls.isEmpty else { return false }
        onDropItems(content.urls)
        return true
    }
}

struct ShelfDotArea: NSViewRepresentable {
    var shelfID: UUID
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var onTargeted: (Bool) -> Void
    var onDropItems: ([URL]) -> Void
    var onReorder: (UUID) -> Void
    var menuProvider: () -> NSMenu?

    func makeNSView(context: Context) -> ShelfDotView {
        let view = ShelfDotView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ShelfDotView, context: Context) {
        view.shelfID = shelfID
        view.onClick = onClick
        view.onHover = onHover
        view.onTargeted = onTargeted
        view.onDropItems = onDropItems
        view.onReorder = onReorder
        view.menuProvider = menuProvider
    }
}

private struct ShelfDot: View {
    let shelf: Shelf
    let index: Int
    @ObservedObject var store: ShelfStore
    var onSave: (Shelf) -> Void
    var onOpen: () -> Void

    @State private var choosingIcon = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var hovering = false
    @State private var targeted = false

    private var isCurrent: Bool { store.currentIndex == index }
    private static let side: CGFloat = 22

    private var backgroundOpacity: Double {
        if targeted { return 0.24 }
        return hovering ? 0.12 : 0
    }

    var body: some View {
        icon
            .frame(width: Self.side, height: Self.side)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .overlay(
                ShelfDotArea(
                    shelfID: shelf.id,
                    onClick: { withAnimation(.easeOut(duration: 0.24)) { store.select(index) } },
                    onHover: { hovering = $0 },
                    onTargeted: { targeted = $0 },
                    onDropItems: { receive($0) },
                    onReorder: { id in
                        guard let from = store.shelves.firstIndex(where: { $0.id == id }) else { return }
                        withAnimation(.easeOut(duration: 0.2)) { store.moveShelf(from: from, to: index) }
                    },
                    menuProvider: { menu() })
            )
            .animation(.easeOut(duration: 0.14), value: backgroundOpacity)
            .help("\(shelf.name) — \(shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items")")
            .popover(isPresented: $choosingIcon, arrowEdge: .bottom) {
                ShelfIconPicker(symbol: shelf.symbol) { symbol in
                    guard store.shelves.indices.contains(index) else { return }
                    store.shelves[index].symbol = symbol
                    choosingIcon = false
                }
            }
            .popover(isPresented: $renaming, arrowEdge: .bottom) {
                HStack(spacing: 6) {
                    TextField("Shelf name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onSubmit { commitRename() }
                    Button("Save") { commitRename() }
                }
                .padding(10)
            }
    }

    @ViewBuilder
    private var icon: some View {
        // The shelf you're on is at full strength, the others are dimmed.
        let opacity = isCurrent ? 1.0 : (hovering ? 0.75 : 0.45)
        switch shelf.symbol {
        case .none:
            Circle()
                .fill(Color.primary.opacity(opacity))
                .frame(width: 6, height: 6)
        case .emoji(let character):
            Text(character)
                .font(.system(size: 12))
                .opacity(opacity)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .opacity(opacity)
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addAction("Change Shelf Icon…") { choosingIcon = true }
        menu.addAction("Rename…") { draft = shelf.name; renaming = true }
        menu.addItem(.separator())
        menu.addAction("New Shelf", enabled: store.canAddShelf) { store.select(store.addShelf()) }
        menu.addAction("Save Shelf…") { onSave(shelf) }
        menu.addAction("Open Shelf…") { onOpen() }
        menu.addItem(.separator())
        menu.addAction("Delete Shelf", enabled: store.shelves.count > 1 && shelf.items.isEmpty) {
            store.removeShelf(at: index)
        }
        return menu
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, store.shelves.indices.contains(index) { store.shelves[index].name = name }
        renaming = false
    }

    /// Screenshots dragged from a shelf move here; files from elsewhere are added.
    private func receive(_ urls: [URL]) {
        for url in urls {
            let standardized = url.standardizedFileURL
            if let item = store.allItems.first(where: { $0.url.standardizedFileURL == standardized }) {
                store.move([item], toShelf: index)
            } else {
                let saved = store.currentIndex
                store.currentIndex = index
                store.add(url, isReference: true)
                store.currentIndex = saved
            }
        }
    }
}

/// Emoji and symbol picker, with a search field, in the style of the macOS
/// icon pickers.
struct ShelfIconPicker: View {
    let symbol: ShelfSymbol
    var onPick: (ShelfSymbol) -> Void

    @State private var showingEmoji: Bool
    @State private var query = ""

    init(symbol: ShelfSymbol, onPick: @escaping (ShelfSymbol) -> Void) {
        self.symbol = symbol
        self.onPick = onPick
        if case .emoji = symbol {
            _showingEmoji = State(initialValue: true)
        } else {
            _showingEmoji = State(initialValue: false)
        }
    }

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8)

    private var choices: [String] {
        let all = showingEmoji ? ShelfSymbol.emojiChoices : ShelfSymbol.symbolChoices
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { ShelfSymbol.searchText(for: $0).contains(needle) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $showingEmoji) {
                    Text("Emoji").tag(true)
                    Text("Icon").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    onPick(.none)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("No icon")
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08)))

            if choices.isEmpty {
                Text("Nothing matches “\(query)”")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 240)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(choices, id: \.self) { choice in
                            let value: ShelfSymbol = showingEmoji ? .emoji(choice) : .symbol(choice)
                            Button { onPick(value) } label: {
                                Group {
                                    if showingEmoji {
                                        Text(choice).font(.system(size: 16))
                                    } else {
                                        Image(systemName: choice).font(.system(size: 14))
                                    }
                                }
                                .frame(width: 30, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(symbol == value ? Color.accentColor.opacity(0.25) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(ShelfSymbol.searchText(for: choice))
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(height: 240)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
