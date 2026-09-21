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
        if targeted { return 0.28 }
        if isCurrent { return 0.18 }
        return hovering ? 0.12 : 0
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.24)) { store.select(index) } } label: {
            icon
                .frame(width: Self.side, height: Self.side)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(backgroundOpacity))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HoverTracker { hovering = $0 })
        .animation(.easeOut(duration: 0.14), value: backgroundOpacity)
        .help("\(shelf.name) — \(shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items")")
        .onDrag {
            NSItemProvider(object: "\(ShelfDots.reorderPrefix)\(shelf.id.uuidString)" as NSString)
        }
        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $targeted) { providers in
            receive(providers)
            return true
        }
        .contextMenu {
            Button("Change Shelf Icon…") { choosingIcon = true }
            Button("Rename…") { draft = shelf.name; renaming = true }
            Divider()
            Button("New Shelf") { store.select(store.addShelf()) }
                .disabled(!store.canAddShelf)
            Button("Save Shelf…") { onSave(shelf) }
            Button("Open Shelf…") { onOpen() }
            Divider()
            Button("Delete Shelf") { store.removeShelf(at: index) }
                .disabled(store.shelves.count < 2 || !shelf.items.isEmpty)
        }
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
        let opacity = isCurrent ? 1.0 : (hovering ? 0.85 : 0.55)
        switch shelf.symbol {
        case .none:
            Circle()
                .fill(Color.primary.opacity(isCurrent ? 0.85 : 0.5))
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

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, store.shelves.indices.contains(index) { store.shelves[index].name = name }
        renaming = false
    }

    /// Three kinds of drop: another shelf (reorder), a screenshot from a shelf
    /// (move it here), or a file from elsewhere (add it here).
    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String, text.hasPrefix(ShelfDots.reorderPrefix) else { return }
                    let id = String(text.dropFirst(ShelfDots.reorderPrefix.count))
                    DispatchQueue.main.async {
                        guard let from = store.shelves.firstIndex(where: { $0.id.uuidString == id }) else { return }
                        store.moveShelf(from: from, to: index)
                    }
                }
                continue
            }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
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
