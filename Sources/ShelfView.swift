import SwiftUI

enum ShelfLayout {
    static let collapsed = CGSize(width: 150, height: 150)
    static let corner: CGFloat = 24
    static let tile: CGFloat = 92
    static let gap: CGFloat = 10
    static let pad: CGFloat = 16
    static let columns = 3
    static let headerHeight: CGFloat = 24
    static let maxRows = 4

    static func size(expanded: Bool, count: Int) -> CGSize {
        guard expanded else { return collapsed }
        let rows = min(maxRows, max(1, Int(ceil(Double(count) / Double(columns)))))
        let w = pad * 2 + CGFloat(columns) * tile + CGFloat(columns - 1) * gap
        let h = pad * 2 + headerHeight + gap + CGFloat(rows) * tile + CGFloat(rows - 1) * gap
        return CGSize(width: w, height: h)
    }
}

/// The native macOS glass material behind the shelf.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    var onDismiss: () -> Void
    var onSettings: () -> Void
    var onDragChanged: () -> Void
    var onDragEnded: () -> Void

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { _ in onDragChanged() }
            .onEnded { _ in onDragEnded() }
    }

    private func expand() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { store.expanded = true }
    }

    var body: some View {
        ZStack {
            GlassBackground()
            // Hover: the whole shelf gets about 10% darker.
            Color.black
                .opacity(store.hovering ? 0.10 : 0)
                .allowsHitTesting(false)
            if store.isEmpty {
                emptyContent
            } else if store.expanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .background(HoverTracker { inside in
            store.hovering = inside
            if inside { store.refreshThumbnails() } // picks up edits made in Preview
        })
        .animation(.easeOut(duration: 0.16), value: store.hovering)
        .clipShape(RoundedRectangle(cornerRadius: ShelfLayout.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShelfLayout.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { closeButton }
    }

    // MARK: - Collapsed: a single stack

    private var collapsedContent: some View {
        VStack(spacing: 8) {
            ZStack {
                ForEach(Array(stackPreview.enumerated()), id: \.element.id) { index, item in
                    let depth = Double(stackPreview.count - 1 - index)
                    Thumbnail(image: item.thumbnail, side: 84, mode: .fill)
                        .rotationEffect(.degrees(depth * -(4 + 1.5 * fan)))
                        .offset(x: depth * -(3 + 2.5 * fan), y: depth * (3 + 2.5 * fan))
                        .opacity(1.0 - depth * 0.12)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: fan)
            .frame(width: 96, height: 96)
            // Drag the whole stack to another app in one go.
            .overlay(
                DragOutArea(
                    items: { store.items.map { (url: $0.url, image: $0.thumbnail) } },
                    onClick: { _ in expand() })
            )

            Text(store.items.count == 1 ? "1 screenshot" : "\(store.items.count) screenshots")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .gesture(swipe)
        .help("Drag the stack into an app, click to expand, or swipe the shelf away")
    }

    /// On hover, a stack of several screenshots fans out by a few percent.
    private var fan: Double {
        store.hovering && store.items.count > 1 ? 1 : 0
    }

    // MARK: - Empty (summoned via shortcut or hot corner)

    private var emptyContent: some View {
        VStack(spacing: 8) {
            Image(nsImage: settings.icon.symbol)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .foregroundColor(.secondary)
            Text("No screenshots yet")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(swipe)
        .overlay(alignment: .topLeading) { settingsButton.padding(8) }
    }

    /// The top three screenshots form the visible stack.
    private var stackPreview: [ShelfItem] {
        Array(store.items.suffix(3))
    }

    // MARK: - Expanded: every screenshot on its own

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: ShelfLayout.gap) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(ShelfLayout.tile), spacing: ShelfLayout.gap),
                                   count: ShelfLayout.columns),
                    spacing: ShelfLayout.gap
                ) {
                    ForEach(store.items) { item in
                        ShelfTile(item: item, store: store, settings: settings)
                    }
                }
                // The gaps between screenshots live inside the scroll view.
                .background(selectionCanvas)
            }
        }
        .padding(ShelfLayout.pad)
        .background(selectionCanvas)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                store.clearSelection()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { store.expanded = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse")

            Text(headerTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Spacer(minLength: 8)

            settingsButton
        }
        .padding(.trailing, 20) // room for the close button
        .frame(height: ShelfLayout.headerHeight)
        .contentShape(Rectangle())
        .gesture(swipe)
    }

    private var selectionCanvas: some View {
        SelectionCanvas(onClick: { store.clearSelection() }, selection: store.paintSelection)
    }

    private var headerTitle: String {
        if !store.selection.isEmpty { return "\(store.selection.count) of \(store.items.count) selected" }
        return store.items.count == 1 ? "1 screenshot" : "\(store.items.count) screenshots"
    }

    // MARK: - Buttons

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.primary.opacity(0.7))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help(store.isEmpty ? "Hide shelf" : "Close the shelf and move everything to \(settings.saveFolder.lastPathComponent)")
    }
}

/// One screenshot on the expanded shelf: draggable into any app, ⌘-click or
/// hold-and-move to select several, double-click to open in Preview, and quick
/// actions on hover.
private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    @State private var hovering = false
    @State private var justCopied = false

    private static let barWidth: CGFloat = 70
    private static let barHeight: CGFloat = 22
    private static let inset: CGFloat = 4
    private static let closeSize: CGFloat = 22

    private var selected: Bool { store.isSelected(item) }
    /// Actions apply to the whole selection when this screenshot is part of it.
    private var targets: [ShelfItem] { store.targets(for: item) }

    private func describe(_ verb: String) -> String {
        targets.count > 1 ? "\(verb) \(targets.count) screenshots" : verb
    }

    var body: some View {
        Thumbnail(image: item.thumbnail, side: ShelfLayout.tile, mode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
            )
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(Self.inset)
                }
            }
            .overlay(
                DragOutArea(
                    items: { targets.map { (url: $0.url, image: $0.thumbnail) } },
                    onClick: { flags in
                        if flags.contains(.command) { store.toggleSelection(item) } else { store.clearSelection() }
                    },
                    onDoubleClick: { store.openInPreview([item]) },
                    onHover: { hovering = $0 },
                    passesThrough: { point, size in
                        guard hovering else { return false }
                        let inBar = point.y <= Self.inset + Self.barHeight
                            && abs(point.x - size.width / 2) <= Self.barWidth / 2
                        let inClose = point.x >= size.width - Self.closeSize
                            && point.y >= size.height - Self.closeSize
                        return inBar || inClose
                    },
                    itemID: item.id,
                    selection: store.paintSelection)
            )
            .overlay(alignment: .topTrailing) {
                if hovering { closeButton }
            }
            .overlay(alignment: .bottom) {
                if hovering { actionBar }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(item.url.lastPathComponent)
    }

    private var closeButton: some View {
        Button {
            store.dispose(targets, action: settings.closeScreenshotAction)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(Self.inset)
        .help(settings.closeScreenshotAction == .trash
              ? describe("Move to Trash")
              : describe("Save to \(settings.saveFolder.lastPathComponent)"))
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            QuickAction(symbol: justCopied ? "checkmark" : "doc.on.doc", help: describe("Copy")) {
                store.copy(targets)
                justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
            }
            QuickAction(symbol: "eye", help: describe("Open in Preview")) {
                store.openInPreview(targets)
            }
            QuickAction(symbol: "trash", help: describe("Move to Trash")) {
                store.dispose(targets, action: .trash)
            }
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .padding(.bottom, Self.inset)
    }
}

private struct QuickAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.white.opacity(hovering ? 1 : 0.82))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HoverTracker { hovering = $0 })
        .help(help)
    }
}

private struct Thumbnail: View {
    let image: NSImage
    let side: CGFloat
    /// `fill` for the stack (looks like cards), `fit` on the expanded shelf so a
    /// wide screenshot stays recognizable.
    let mode: ContentMode

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: mode)
            .frame(width: side, height: side)
            .background(mode == .fit ? Color.black.opacity(0.22) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 2)
    }
}
