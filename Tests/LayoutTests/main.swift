import AppKit
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Fixtures.isolateStorage()

/// Builds the shelf at the size the panel gives it, and reports how much taller
/// the screenshots are than the space they get: anything over 0 means the shelf
/// clips them and starts scrolling.
func overflow(screenshots: Int, size: ThumbnailSize, spreadOverDays: Bool = false) -> CGFloat {
    AppSettings.shared.thumbnailSize = size
    let store = ShelfStore()
    store.shelves = [Shelf(name: "Shelf 1")]
    store.currentIndex = 0
    for i in 0..<screenshots {
        let date = spreadOverDays ? Calendar.current.date(byAdding: .day, value: -i * 3, to: Date()) : nil
        store.add(Fixtures.image(hue: Double(i % 5) / 5, date: date))
    }
    store.expanded = true

    let frame = ShelfLayout.size(expanded: true, groups: store.groups)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: frame), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView: ShelfView(store: store, settings: .shared, onDismiss: {}, onSettings: {},
                                                    onSaveShelf: { _ in }, onOpenShelf: {},
                                                    onDragChanged: {}, onDragEnded: {}))
    hosting.frame = NSRect(origin: .zero, size: frame)
    window.contentView = hosting
    window.orderFrontRegardless()
    spin(0.8)
    var scrollViews: [NSScrollView] = []
    func walk(_ view: NSView) {
        if let scroll = view as? NSScrollView { scrollViews.append(scroll) }
        view.subviews.forEach(walk)
    }
    walk(hosting)
    window.orderOut(nil)
    guard let scroll = scrollViews.first, let document = scroll.documentView else { return -1 }
    return document.frame.height - scroll.contentView.bounds.height
}

Check.section("The screenshots fit without scrolling")
for size in ThumbnailSize.allCases {
    for count in [0, 1, 2, 3, 4, 6] {
        let extra = overflow(screenshots: count, size: size)
        Check.ok(extra <= 0.5, "\(size.label), \(count): \(extra > 0.5 ? "\(Int(extra)) pt too tall" : "fits")")
    }
}
Check.section("With date labels")
for count in [2, 3] {
    let extra = overflow(screenshots: count, size: .small, spreadOverDays: true)
    Check.ok(extra <= 0.5, "\(count) screenshots on different days: \(extra > 0.5 ? "\(Int(extra)) pt too tall" : "fits")")
}
Check.section("A full shelf")
Check.ok(overflow(screenshots: 30, size: .small) > 0, "30 screenshots do scroll")
Check.ok(ShelfLayout.size(expanded: false, groups: []) == ShelfLayout.collapsed, "collapsed is a square")

Fixtures.cleanUp()
Check.finish()
