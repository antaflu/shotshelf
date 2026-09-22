import SwiftUI

/// Shelf measurements. Tile and shelf sizes follow the Thumbnail size setting.
enum ShelfLayout {
    private static var preset: ThumbnailSize { AppSettings.shared.thumbnailSize }
    static var collapsed: CGSize { CGSize(width: preset.collapsed, height: preset.collapsed) }
    static let corner: CGFloat = 24
    static var tile: CGFloat { preset.tile }
    /// The cards in the collapsed stack, and the area they sit in.
    static var stackCard: CGFloat { (preset.collapsed * 0.56).rounded() }
    static var stackArea: CGFloat { (preset.collapsed * 0.64).rounded() }
    static let gap: CGFloat = 10
    static let pad: CGFloat = 16
    /// Room inside the scroll area so a tile that grows on hover isn't clipped.
    /// Taken out of `pad` and `gap`, so the shelf keeps the same size.
    static let hoverRoom: CGFloat = 4
    static let columns = 3
    static let headerHeight: CGFloat = 24
    /// The "Today" / "Last week" labels between groups.
    static let groupHeader: CGFloat = 15
    /// The strip at the bottom holding the gear.
    static let footerHeight: CGFloat = 18
    static let maxRows = 4

    static func rows(_ count: Int) -> Int {
        max(1, Int(ceil(Double(count) / Double(columns))))
    }

    static func size(expanded: Bool, groups: [ShelfGroup]) -> CGSize {
        guard expanded else { return collapsed }
        let showTitles = groups.count > 1
        // An empty shelf keeps one row's worth of room for its placeholder.
        var content: CGFloat = groups.isEmpty ? tile : 0
        for (index, group) in groups.enumerated() {
            if index > 0 { content += gap }
            if showTitles { content += groupHeader + gap }
            let rows = CGFloat(rows(group.items.count))
            content += rows * tile + (rows - 1) * gap
        }
        // Room for a couple of date labels on top of the rows, so grouping
        // doesn't squeeze the shelf.
        let extraForTitles = showTitles ? CGFloat(min(groups.count - 1, 2)) * (groupHeader + gap) : 0
        let maxContent = CGFloat(maxRows) * tile + CGFloat(maxRows - 1) * gap + extraForTitles
        let w = pad * 2 + CGFloat(columns) * tile + CGFloat(columns - 1) * gap
        // Everything the expanded shelf stacks up, top to bottom: padding, the
        // header, a gap, the screenshots, a gap, the footer with the gear.
        // Miss a piece and the screenshots get clipped and start scrolling.
        let h = pad * 2 + headerHeight + gap + min(content, maxContent)
            + (gap - hoverRoom) + footerHeight
        return CGSize(width: w, height: h)
    }
}

/// The Finder-style selection rectangle. `rect` is in window coordinates;
/// the shelf view fills the whole window, so only the y axis needs flipping.
private struct MarqueeView: View {
    let rect: NSRect?

    var body: some View {
        GeometryReader { geometry in
            if let rect {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: geometry.size.height - rect.midY)
            }
        }
        .allowsHitTesting(false)
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
    var onSaveShelf: (Shelf) -> Void = { _ in }
    var onOpenShelf: () -> Void = {}
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
            if store.isEmpty && !store.expanded {
                emptyContent
            } else if store.expanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .overlay(MarqueeView(rect: store.marquee))
        .overlay(
            RoundedRectangle(cornerRadius: ShelfLayout.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(store.dropTargeted ? 0.55 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        )
        .animation(.easeOut(duration: 0.18), value: store.dropTargeted)
        .background(HoverTracker { inside in
            store.hovering = inside
            if inside { store.refreshThumbnails() } // picks up edits made in Preview
        })
        .animation(.easeOut(duration: 0.2), value: store.hovering)
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
                    Thumbnail(image: item.thumbnail, side: ShelfLayout.stackCard, mode: .fill)
                        .rotationEffect(.degrees(depth * -(4 + 1.5 * fan)))
                        .offset(x: depth * -(3 + 2.5 * fan), y: depth * (3 + 2.5 * fan))
                        .opacity(1.0 - depth * 0.12)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: fan)
            .frame(width: ShelfLayout.stackArea, height: ShelfLayout.stackArea)
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
            VStack(spacing: 2) {
                Text(store.dropTargeted ? "Drop to keep it here"
                     : (store.allItems.isEmpty ? "No screenshots yet" : "This shelf is empty"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if !store.dropTargeted {
                    Text(store.allItems.isEmpty ? "Drag images here" : "Click to see your shelves")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .gesture(swipe)
        .overlay(alignment: .bottomTrailing) { settingsButton.padding(8) }
    }

    /// The top three screenshots form the visible stack.
    private var stackPreview: [ShelfItem] {
        Array(store.items.suffix(3))
    }

    // MARK: - Expanded: every screenshot on its own

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: ShelfLayout.gap - ShelfLayout.hoverRoom) {
            header
                .padding([.horizontal, .top], ShelfLayout.hoverRoom)
            ScrollView(.vertical, showsIndicators: false) {
                let groups = store.groups
                VStack(alignment: .leading, spacing: ShelfLayout.gap) {
                    if groups.isEmpty { emptyShelfPlaceholder }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: ShelfLayout.gap) {
                            // Only worth labelling when there is more than one day on the shelf.
                            if groups.count > 1 {
                                Text(group.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(height: ShelfLayout.groupHeader, alignment: .leading)
                            }
                            grid(for: group.items)
                        }
                    }
                }
                // Switching shelves slides the screenshots in from the side.
                .id(store.current.id)
                .transition(.asymmetric(
                    insertion: .move(edge: store.switchedForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: store.switchedForward ? .leading : .trailing).combined(with: .opacity)))
                .padding(ShelfLayout.hoverRoom)
                // The gaps between screenshots live inside the scroll view.
                .background(selectionCanvas)
            }
            // The gear sits in the bottom-right corner.
            HStack(spacing: 0) {
                Spacer()
                settingsButton
            }
            .frame(height: ShelfLayout.footerHeight)
            .padding(.horizontal, ShelfLayout.hoverRoom)
        }
        .padding(ShelfLayout.pad - ShelfLayout.hoverRoom)
        .background(selectionCanvas)
    }

    private func grid(for items: [ShelfItem]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(ShelfLayout.tile), spacing: ShelfLayout.gap,
                                               alignment: .topLeading),
                           count: ShelfLayout.columns),
            alignment: .leading,
            spacing: ShelfLayout.gap
        ) {
            ForEach(items) { item in
                ShelfTile(item: item, store: store, settings: settings)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
            Text(headerTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 6)
            ShelfDots(store: store, onSave: onSaveShelf, onOpen: onOpenShelf)
        }
        .foregroundColor(.secondary)
        .padding(.trailing, 20) // room for the close button
        .frame(height: ShelfLayout.headerHeight)
        // Anywhere that isn't a button collapses the shelf.
        .contentShape(Rectangle())
        .onTapGesture {
            store.clearSelection()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { store.expanded = false }
        }
        .help("Collapse")
        .gesture(swipe)
    }

    /// What an empty shelf shows while it's open, so the header and the other
    /// shelves stay in reach.
    private var emptyShelfPlaceholder: some View {
        VStack(spacing: 4) {
            Text("Nothing on \(store.current.name) yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text("Take a screenshot, drop images here, or right-click to paste")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ShelfLayout.tile)
        .allowsHitTesting(false)
    }

    private var selectionCanvas: some View {
        SelectionCanvas(onClick: { store.clearSelection() }, selection: store.marqueeSelection,
                        menuProvider: { ShelfMenus.paste(into: store) })
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

/// One screenshot on the expanded shelf: click to copy, drag into any app,
/// ⌘-click or drag a rectangle to select several, double-click to open in
/// Preview.
///
/// On hover it grows slightly and shows × in the top-right. With quick actions
/// turned on in Settings, Copy and View also sit large in the middle and
/// Delete in the bottom-left; × then only shows when it does something Delete
/// doesn't (saving to the folder, or letting go of a dragged-in file). They are drawn here but clicked through the
/// drag area underneath (see `Hotspot`), so a drag can start anywhere.
private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    @State private var hovering = false
    @State private var hoveredSpot: String?
    @State private var justCopied = false
    @State private var copyToken = 0

    private enum Spot {
        static let copy = "copy", view = "view", delete = "delete", close = "close"
    }
    private static let pillSize = CGSize(width: 66, height: 22)
    private static let pillGap: CGFloat = 4
    private static let inset: CGFloat = 4
    private static let deleteSize: CGFloat = 20
    private static let closeSize: CGFloat = 14

    private var selected: Bool { store.isSelected(item) }
    /// Actions apply to the whole selection when this screenshot is part of it.
    private var targets: [ShelfItem] { store.targets(for: item) }
    private var quickActions: Bool { settings.hoverQuickActions }
    private var canDelete: Bool { quickActions && !item.isReference }
    private var showsClose: Bool {
        !quickActions || item.isReference || settings.closeScreenshotAction == .save
    }

    private func describe(_ verb: String) -> String {
        targets.count > 1 ? "\(verb) \(targets.count) items" : verb
    }

    /// Where the buttons are, in the tile's bottom-left-origin coordinates.
    private func hotspots(in size: NSSize) -> [Hotspot] {
        guard hovering else { return [] }
        let pill = Self.pillSize, gap = Self.pillGap / 2
        var spots: [Hotspot] = []
        if quickActions {
            spots += [
                Hotspot(id: Spot.copy, rect: NSRect(x: size.width / 2 - pill.width / 2, y: size.height / 2 + gap,
                                                    width: pill.width, height: pill.height)),
                Hotspot(id: Spot.view, rect: NSRect(x: size.width / 2 - pill.width / 2, y: size.height / 2 - gap - pill.height,
                                                    width: pill.width, height: pill.height)),
            ]
        }
        if showsClose {
            spots.append(Hotspot(id: Spot.close, rect: NSRect(x: size.width - 22, y: size.height - 22, width: 22, height: 22)))
        }
        if canDelete {
            spots.append(Hotspot(id: Spot.delete, rect: NSRect(x: 2, y: 2, width: Self.deleteSize + 4,
                                                               height: Self.deleteSize + 4)))
        }
        return spots
    }

    private func perform(_ spot: String) {
        switch spot {
        case Spot.copy:
            copy()
        case Spot.view:
            store.openInPreview(targets)
        case Spot.delete:
            store.dispose(targets, action: .trash)
        case Spot.close:
            store.dispose(targets, action: settings.closeScreenshotAction)
        default:
            break
        }
    }

    private func copy() {
        store.copy(targets)
        justCopied = true
        copyToken += 1
        let token = copyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if token == copyToken { justCopied = false }
        }
    }

    /// A plain click copies: the whole selection if this screenshot is part of
    /// it, otherwise just this one.
    private func click(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            store.toggleSelection(item)
            return
        }
        if !(selected && targets.count > 1) { store.clearSelection() }
        copy()
    }

    var body: some View {
        Thumbnail(image: item.thumbnail, side: ShelfLayout.tile, mode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(hovering && quickActions ? 0.16 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
            )
            .overlay(alignment: .topLeading) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(Self.inset)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.7)
            }
            // The buttons stay in place and fade, so hovering feels soft.
            .overlay {
                if quickActions {
                    VStack(spacing: Self.pillGap) {
                        pill(symbol: justCopied ? "checkmark" : "doc.on.doc",
                             title: justCopied ? "Copied" : "Copy", spot: Spot.copy)
                        pill(symbol: "eye", title: "View", spot: Spot.view)
                    }
                    .revealed(hovering)
                } else {
                    copiedBadge.revealed(justCopied)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsClose { closeMark.revealed(hovering) }
            }
            .overlay(alignment: .bottomLeading) {
                if canDelete { deleteMark.revealed(hovering) }
            }
            .overlay(
                DragOutArea(
                    items: { targets.map { (url: $0.url, image: $0.thumbnail) } },
                    onClick: { click($0) },
                    onDoubleClick: { store.openInPreview([item]) },
                    onHover: { hovering = $0 },
                    hotspots: { hotspots(in: $0) },
                    onHotspotClick: { perform($0) },
                    onHotspotHover: { hoveredSpot = $0 },
                    menuProvider: { contextMenu() },
                    itemID: item.id,
                    selection: store.marqueeSelection)
            )
            .scaleEffect(hovering ? 1.04 : 1)
            .zIndex(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.15), value: selected)
            .animation(.easeOut(duration: 0.12), value: hoveredSpot)
            .animation(.easeOut(duration: 0.16), value: justCopied)
            .help(helpText)
    }

    private var copiedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text(targets.count > 1 ? "Copied \(targets.count)" : "Copied")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    /// The native right-click menu. Acts on the whole selection when this
    /// screenshot is part of it.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let picked = targets
        menu.addAction(describe("Copy")) { store.copy(picked) }
        menu.addAction(describe("Open in Preview")) { store.openInPreview(picked) }
        menu.addItem(.separator())
        menu.addAction(describe("Save to \(settings.saveFolder.lastPathComponent)"),
                       enabled: !picked.contains(where: \.isReference)) {
            store.disposeEverywhere(picked, action: .save)
        }
        menu.addAction(picked.contains(where: \.isReference) ? describe("Remove from Shelf") : describe("Delete")) {
            store.disposeEverywhere(picked, action: .trash)
        }
        menu.addItem(.separator())

        let move = NSMenu()
        for (index, shelf) in store.shelves.enumerated() where index != store.currentIndex {
            move.addAction(shelf.name) { store.move(picked, toShelf: index) }
        }
        move.addAction("New Shelf", enabled: store.canAddShelf) {
            let index = store.addShelf()
            store.move(picked, toShelf: index)
            store.select(index)
        }
        let moveItem = menu.addItem(withTitle: "Move to Shelf", action: nil, keyEquivalent: "")
        moveItem.submenu = move
        return menu
    }

    private var helpText: String {
        switch hoveredSpot {
        case Spot.copy?: return describe("Copy")
        case Spot.view?: return describe("Open in Preview")
        case Spot.delete?: return describe("Move to Trash")
        case Spot.close?:
            if item.isReference { return "Remove from shelf (the original stays where it is)" }
            return settings.closeScreenshotAction == .trash
                ? describe("Move to Trash")
                : describe("Save to \(settings.saveFolder.lastPathComponent)")
        default:
            let name = item.isReference ? "\(item.url.lastPathComponent) — \(item.url.deletingLastPathComponent().path)"
                                        : item.url.lastPathComponent
            return "\(name)\nClick to copy, double-click to open"
        }
    }

    private func pill(symbol: String, title: String, spot: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 13)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(width: Self.pillSize.width, height: Self.pillSize.height)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().fill(Color.white.opacity(hoveredSpot == spot ? 0.2 : 0)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private var closeMark: some View {
        Image(systemName: "xmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.white)
            .frame(width: Self.closeSize, height: Self.closeSize)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .overlay(Circle().fill(Color.white.opacity(hoveredSpot == Spot.close ? 0.25 : 0)))
            .padding(Self.inset)
    }

    private var deleteMark: some View {
        Image(systemName: "trash")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: Self.deleteSize, height: Self.deleteSize)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .overlay(Circle().fill(Color.white.opacity(hoveredSpot == Spot.delete ? 0.25 : 0)))
            .padding(Self.inset)
    }
}

private extension View {
    /// Fades and gently scales a hover control in and out.
    func revealed(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.94)
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
