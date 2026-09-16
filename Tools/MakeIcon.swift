// Generates ShotShelf.icns: a small stack of "screenshots" on a dark squircle.
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("ShotShelf.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func squirclePath(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.height * 0.2237, transform: nil)
}

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high

    // Background: squircle with a gradient
    let inset = s * 0.09
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.saveGState()
    ctx.addPath(squirclePath(body))
    ctx.clip()
    let colors = [CGColor(red: 0.24, green: 0.27, blue: 0.34, alpha: 1),
                  CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    ctx.restoreGState()

    // Three cards forming a stack
    let cards: [(dx: CGFloat, dy: CGFloat, angle: CGFloat, alpha: CGFloat)] = [
        (-0.055, -0.055, 9, 0.35), (0.0, 0.0, 3.5, 0.6), (0.05, 0.055, -3, 1.0),
    ]
    let cardSize = CGSize(width: s * 0.42, height: s * 0.32)
    for card in cards {
        ctx.saveGState()
        ctx.translateBy(x: s / 2 + card.dx * s, y: s / 2 + card.dy * s)
        ctx.rotate(by: card.angle * .pi / 180)
        let rect = CGRect(x: -cardSize.width / 2, y: -cardSize.height / 2,
                          width: cardSize.width, height: cardSize.height)
        let path = CGPath(roundedRect: rect, cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: card.alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(base)x\(base)\(suffix).png"
    guard let data = render(size: base * scale) else { continue }
    try data.write(to: iconset.appendingPathComponent(name))
}
print(iconset.path)
