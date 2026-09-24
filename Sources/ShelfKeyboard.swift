import AppKit
import Carbon.HIToolbox
import Quartz

/// Quick Look for the selected screenshots, like pressing space in Finder.
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()

    private(set) var urls: [URL] = []

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Space: open, or close it again.
    func toggle(_ urls: [URL]) {
        if isOpen {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        show(urls)
    }

    /// Clicking View or double-clicking: always show these screenshots.
    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

/// The keys that work once you've clicked a screenshot, as in Finder:
/// space previews, ⌘C copies, ⌘A selects all, ⌘⌫ moves to the Trash, Escape
/// clears the selection and the arrow keys step through the screenshots.
struct ShelfKeyboard {
    let store: ShelfStore


    /// True when the key was used, so it isn't passed on.
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, store.expanded else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let selected = store.selectedItems

        switch (Int(event.keyCode), flags) {
        case (kVK_Space, []):
            guard !selected.isEmpty else { return false }
            store.quickLook(selected, toggle: true)
        case (kVK_ANSI_C, [.command]):
            guard !selected.isEmpty else { return false }
            store.copy(selected)
        case (kVK_ANSI_A, [.command]):
            store.selectAll()
        case (kVK_Delete, [.command]), (kVK_ForwardDelete, []):
            guard !selected.isEmpty else { return false }
            store.dispose(selected, action: .trash)
        case (kVK_Escape, []):
            guard !selected.isEmpty else { return false }
            store.clearSelection()
        case (kVK_LeftArrow, []): store.moveSelection(by: -1)
        case (kVK_RightArrow, []): store.moveSelection(by: 1)
        case (kVK_UpArrow, []): store.moveSelection(by: -ShelfLayout.columns)
        case (kVK_DownArrow, []): store.moveSelection(by: ShelfLayout.columns)
        default:
            return false
        }
        return true
    }
}
