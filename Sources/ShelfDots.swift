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

/// The row of shelf dots in the header. Click one to switch shelves, drag
/// screenshots onto one to move them there, right-click for its menu.
struct ShelfDots: View {
    @ObservedObject var store: ShelfStore
    var onSave: (Shelf) -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(store.shelves.enumerated()), id: \.element.id) { index, shelf in
                ShelfDot(shelf: shelf, index: index, store: store, onSave: onSave, onOpen: onOpen)
            }
            if store.canAddShelf {
                Button {
                    store.select(store.addShelf())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New shelf")
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
    @State private var targeted = false

    private var isCurrent: Bool { store.currentIndex == index }

    var body: some View {
        Button { store.select(index) } label: {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(isCurrent ? 0.22 : 0.10))
                    .frame(width: 16, height: 16)
                if let image = shelf.symbol.image(pointSize: 9, color: .white) {
                    Image(nsImage: image)
                        .opacity(isCurrent ? 1 : 0.65)
                } else {
                    Circle()
                        .fill(Color.primary.opacity(isCurrent ? 0.9 : 0.45))
                        .frame(width: 5, height: 5)
                }
            }
            .overlay(
                Circle().strokeBorder(Color.accentColor, lineWidth: isCurrent ? 1.5 : 0)
                    .frame(width: 18, height: 18)
            )
            .overlay(
                Circle().strokeBorder(Color.white.opacity(targeted ? 0.8 : 0), lineWidth: 1.5)
                    .frame(width: 19, height: 19)
            )
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(shelf.name) — \(shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items")")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
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

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { store.shelves[index].name = name }
        renaming = false
    }

    /// Screenshots dragged from another shelf move here; files from elsewhere
    /// are added to this shelf.
    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
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

/// Emoji or SF Symbol picker, in the style of the macOS icon pickers.
struct ShelfIconPicker: View {
    let symbol: ShelfSymbol
    var onPick: (ShelfSymbol) -> Void

    @State private var showingEmoji: Bool

    init(symbol: ShelfSymbol, onPick: @escaping (ShelfSymbol) -> Void) {
        self.symbol = symbol
        self.onPick = onPick
        if case .emoji = symbol { _showingEmoji = State(initialValue: true) } else { _showingEmoji = State(initialValue: false) }
    }

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 10) {
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

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    if showingEmoji {
                        ForEach(ShelfSymbol.emojiChoices, id: \.self) { emoji in
                            cell(isSelected: symbol == .emoji(emoji)) { onPick(.emoji(emoji)) } content: {
                                Text(emoji).font(.system(size: 16))
                            }
                        }
                    } else {
                        ForEach(ShelfSymbol.symbolChoices, id: \.self) { name in
                            cell(isSelected: symbol == .symbol(name)) { onPick(.symbol(name)) } content: {
                                Image(systemName: name)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .frame(height: 210)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func cell<Content: View>(isSelected: Bool, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
