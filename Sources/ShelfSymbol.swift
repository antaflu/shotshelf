import AppKit

/// The little icon on a shelf's dot: an emoji, an SF Symbol, or nothing.
enum ShelfSymbol: Equatable, Codable {
    case none
    case symbol(String)
    case emoji(String)

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        switch try container.decode(String.self, forKey: .kind) {
        case "symbol": self = value.isEmpty ? .none : .symbol(value)
        case "emoji": self = value.isEmpty ? .none : .emoji(value)
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case .symbol(let name):
            try container.encode("symbol", forKey: .kind)
            try container.encode(name, forKey: .value)
        case .emoji(let character):
            try container.encode("emoji", forKey: .kind)
            try container.encode(character, forKey: .value)
        }
    }

    /// The icons offered in the picker, in the order they're shown.
    static let symbolChoices = [
        "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill",
        "asterisk", "bell.fill", "lightbulb.fill", "drop.triangle.fill", "square.grid.2x2.fill",
        "circle.grid.3x3.fill", "square.stack.3d.up.fill", "cylinder.split.1x2.fill", "archivebox.fill",
        "square.on.square", "folder.fill", "tray.full.fill", "calendar", "envelope.fill",
        "checkmark.square.fill", "doc.fill", "book.fill", "bubble.left.fill", "person.2.fill",
        "terminal.fill", "hammer.fill", "square.fill", "drop.fill", "circle.fill", "moon.fill",
        "sun.max.fill", "globe.europe.africa.fill", "leaf.fill", "cloud.fill", "pawprint.fill",
        "house.fill", "gift.fill", "bed.double.fill", "fork.knife", "dumbbell.fill", "airplane",
        "music.note", "paintpalette.fill", "video.fill", "bandage.fill", "chevron.left.forwardslash.chevron.right",
        "baseball.fill", "cloud.sun.fill", "map.fill", "flame.fill", "square.3.layers.3d", "figure.walk",
        "note.text", "hand.thumbsup.fill", "tram.fill",
    ]

    static let emojiChoices = [
        "📸", "⭐️", "❤️", "🔥", "✅", "📌", "🎯", "💡", "📁", "🗂", "📝", "🎨", "🧪", "🐛", "🚀", "🧠",
        "💬", "📊", "💸", "🛒", "🎬", "🎵", "🌍", "🌱", "☕️", "🍕", "🐱", "🐶", "🌈", "⚡️", "🔒", "🔧",
    ]

    /// The image for a shelf dot, or nil when the shelf has no icon.
    func image(pointSize: CGFloat, color: NSColor) -> NSImage? {
        switch self {
        case .none:
            return nil
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        case .emoji(let character):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize)]
            let text = character as NSString
            let size = text.size(withAttributes: attributes)
            let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
            image.lockFocus()
            text.draw(at: .zero, withAttributes: attributes)
            image.unlockFocus()
            return image
        }
    }
}
