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
        .background(HoverTracker { store.hovering = $0 })
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
                    onClick: { expand() })
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
                        ShelfTile(item: item) { store.flush(item) }
                    }
                }
            }
        }
        .padding(ShelfLayout.pad)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
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

            Text(store.items.count == 1 ? "1 screenshot" : "\(store.items.count) screenshots")
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

/// One screenshot on the expanded shelf, draggable into any other app.
private struct ShelfTile: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Thumbnail(image: item.thumbnail, side: ShelfLayout.tile, mode: .fit)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Move to save folder")
                }
            }
            .background(HoverTracker { hovering = $0 })
            .onDrag {
                let provider = NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                provider.suggestedName = item.url.lastPathComponent
                return provider
            }
            .help(item.url.lastPathComponent)
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
