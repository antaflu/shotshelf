import AppKit
import Carbon.HIToolbox
import Combine

enum ScreenCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum HotCornerAction: String, CaseIterable, Identifiable {
    case enter, horizontalScroll

    var id: String { rawValue }
    var label: String {
        switch self {
        case .enter: return "Move pointer into corner"
        case .horizontalScroll: return "Scroll sideways in corner"
        }
    }
}

enum IconChoice: String, CaseIterable, Identifiable {
    case stack = "square.stack.3d.up.fill"
    case photos = "photo.stack.fill"
    case viewfinder = "camera.viewfinder"
    case cards = "rectangle.stack.fill"
    case tray = "tray.full.fill"
    case scissors = "scissors"

    var id: String { rawValue }

    /// The symbol, with a fallback for systems where it does not exist.
    var symbol: NSImage {
        NSImage(systemSymbolName: rawValue, accessibilityDescription: "ShotShelf")
            ?? NSImage(systemSymbolName: IconChoice.stack.rawValue, accessibilityDescription: "ShotShelf")
            ?? NSImage()
    }
}

/// A global shortcut, stored as a virtual key code plus modifiers.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var display: String

    private static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(Self.modifierMask)
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard !mods.isEmpty || isFunctionKey else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = mods.rawValue
        display = Self.symbols(for: mods) + Self.keyName(event)
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let name = functionKeys[code] ?? namedKeys[code] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// All ShotShelf settings, saved straight to UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let saveFolder = "SaveFolder"
        static let showDockIcon = "ShowDockIcon"
        static let showMenuBarIcon = "ShowMenuBarIcon"
        static let icon = "IconChoice"
        static let hideSystemPreview = "HideSystemPreview"
        static let anchorCorner = "AnchorCorner"
        static let shortcut = "ToggleShortcut"
        static let mouseButton = "ToggleMouseButton"
        static let hotCorner = "HotCorner"
        static let hotCornerAction = "HotCornerAction"
        static let autoCheckUpdates = "AutoCheckUpdates"
    }

    private let defaults = UserDefaults.standard

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) }
    }
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }
    @Published var icon: IconChoice {
        didSet { defaults.set(icon.rawValue, forKey: Key.icon) }
    }
    @Published var hideSystemPreview: Bool {
        didSet { defaults.set(hideSystemPreview, forKey: Key.hideSystemPreview) }
    }
    @Published var anchorCorner: ScreenCorner {
        didSet { defaults.set(anchorCorner.rawValue, forKey: Key.anchorCorner) }
    }
    @Published var toggleShortcut: KeyShortcut? {
        didSet {
            if let toggleShortcut, let data = try? JSONEncoder().encode(toggleShortcut) {
                defaults.set(data, forKey: Key.shortcut)
            } else {
                defaults.removeObject(forKey: Key.shortcut)
            }
        }
    }
    /// NSEvent.buttonNumber of an extra mouse button (2 = middle, 3 = back, 4 = forward).
    @Published var toggleMouseButton: Int? {
        didSet { defaults.set(toggleMouseButton, forKey: Key.mouseButton) }
    }
    @Published var hotCorner: ScreenCorner? {
        didSet { defaults.set(hotCorner?.rawValue, forKey: Key.hotCorner) }
    }
    @Published var hotCornerAction: HotCornerAction {
        didSet { defaults.set(hotCornerAction.rawValue, forKey: Key.hotCornerAction) }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Key.autoCheckUpdates) }
    }

    private init() {
        defaults.register(defaults: [
            Key.showDockIcon: false,
            Key.showMenuBarIcon: true,
            Key.hideSystemPreview: true,
            Key.autoCheckUpdates: true,
        ])
        saveFolder = defaults.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppSettings.desktopURL
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        icon = defaults.string(forKey: Key.icon).flatMap(IconChoice.init(rawValue:)) ?? .stack
        hideSystemPreview = defaults.bool(forKey: Key.hideSystemPreview)
        anchorCorner = defaults.string(forKey: Key.anchorCorner).flatMap(ScreenCorner.init(rawValue:)) ?? .bottomRight
        toggleShortcut = defaults.data(forKey: Key.shortcut).flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
        toggleMouseButton = defaults.object(forKey: Key.mouseButton) as? Int
        hotCorner = defaults.string(forKey: Key.hotCorner).flatMap(ScreenCorner.init(rawValue:))
        hotCornerAction = defaults.string(forKey: Key.hotCornerAction).flatMap(HotCornerAction.init(rawValue:)) ?? .enter
        autoCheckUpdates = defaults.bool(forKey: Key.autoCheckUpdates)
    }

    static func mouseButtonName(_ number: Int) -> String {
        switch number {
        case 2: return "Middle button"
        case 3: return "Button 4 (back)"
        case 4: return "Button 5 (forward)"
        default: return "Button \(number + 1)"
        }
    }
}
