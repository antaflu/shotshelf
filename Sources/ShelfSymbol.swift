import AppKit
import CoreImage

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
        "music.note", "paintpalette.fill", "video.fill", "bandage.fill",
        "chevron.left.forwardslash.chevron.right", "baseball.fill", "cloud.sun.fill", "map.fill",
        "flame.fill", "square.3.layers.3d", "figure.walk", "note.text", "hand.thumbsup.fill", "tram.fill",
        "camera.fill", "photo.fill", "scissors", "paperclip", "link", "magnifyingglass", "eye.fill",
        "pin.fill", "tag.fill", "cart.fill", "creditcard.fill", "banknote.fill", "chart.bar.fill",
        "chart.pie.fill", "clock.fill", "alarm.fill", "timer", "stopwatch.fill", "graduationcap.fill",
        "briefcase.fill", "building.2.fill", "car.fill", "bicycle", "ferry.fill", "location.fill",
        "mappin.and.ellipse", "wifi", "antenna.radiowaves.left.and.right", "bolt.horizontal.fill",
        "battery.100", "speaker.wave.2.fill", "mic.fill", "headphones", "gamecontroller.fill",
        "puzzlepiece.fill", "wand.and.stars", "sparkles", "crown.fill", "trophy.fill", "medal.fill",
        "gearshape.fill", "wrench.and.screwdriver.fill", "cube.fill", "shippingbox.fill", "printer.fill",
        "desktopcomputer", "laptopcomputer", "iphone", "applewatch", "keyboard", "externaldrive.fill",
        "internaldrive.fill", "server.rack", "network", "lock.fill", "key.fill", "shield.fill",
        "exclamationmark.triangle.fill", "questionmark.circle.fill", "info.circle.fill", "trash.fill",
        "arrow.down.circle.fill", "arrow.up.circle.fill", "arrow.triangle.2.circlepath", "paperplane.fill",
        "tray.and.arrow.down.fill", "doc.on.doc.fill", "text.alignleft", "list.bullet", "checklist",
        "pencil", "highlighter", "ruler.fill", "compass.drawing", "theatermasks.fill", "film.fill",
        "tv.fill", "book.closed.fill", "newspaper.fill", "bookmark.square.fill", "face.smiling.fill",
        "hand.wave.fill", "figure.run", "sportscourt.fill", "soccerball", "basketball.fill",
        "tennis.racket", "snowflake", "umbrella.fill", "thermometer.medium", "wind", "tornado",
        "hurricane", "sunrise.fill", "sunset.fill", "sparkle", "atom", "brain.head.profile",
        "cross.case.fill", "pills.fill", "stethoscope", "carrot.fill", "cup.and.saucer.fill",
        "birthday.cake.fill", "wineglass.fill", "takeoutbag.and.cup.and.straw.fill",
    ]

    /// Every emoji macOS can draw on its own, so the picker has them all.
    static let emojiChoices: [String] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FC, 0x1F7E0...0x1F7EB,
            0x1F90C...0x1F9FF, 0x1FA70...0x1FAF8, 0x2600...0x26FF, 0x2700...0x27BF,
        ]
        var result: [String] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation else { continue }
                result.append(String(scalar))
            }
        }
        return result
    }()

    /// What a search matches on: "rocket", "star.fill", and so on.
    static func searchText(for choice: String) -> String {
        if let scalar = choice.unicodeScalars.first, let name = scalar.properties.name, choice.count == 1 {
            return name.lowercased()
        }
        return choice.replacingOccurrences(of: ".", with: " ")
    }

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
            return ShelfSymbol.emojiImage(character, pointSize: pointSize)
        }
    }

    /// Emoji are colour images, so greying one out means really draining the
    /// colour rather than asking SwiftUI for a filter.
    static func emojiImage(_ character: String, pointSize: CGFloat, grey: Bool = false) -> NSImage? {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize)]
        let text = character as NSString
        let size = text.size(withAttributes: attributes)
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        image.lockFocus()
        text.draw(at: .zero, withAttributes: attributes)
        image.unlockFocus()
        guard grey else { return image }

        guard let tiff = image.tiffRepresentation, let source = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return image }
        let grey = NSImage(size: image.size)
        grey.addRepresentation(NSCIImageRep(ciImage: output))
        return grey
    }
}
