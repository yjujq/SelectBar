import AppKit

/// Рисует иконку приложения во всех нужных размерах.
/// Все координаты заданы в холсте 1024 и масштабируются множителем.

func rounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size) / 1024.0
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Подложка-плитка со скруглением, как у системных иконок.
    let tile = CGRect(x: 62 * s, y: 62 * s, width: 900 * s, height: 900 * s)
    let tilePath = rounded(ctx, tile, 200 * s)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.42, green: 0.55, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.17, green: 0.29, blue: 0.85, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: tile.maxY),
                               end: CGPoint(x: 0, y: tile.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Строки текста. Средняя — выделенная: под ней подложка выделения.
    let lines: [(CGFloat, CGFloat, CGFloat)] = [   // x, ширина, y
        (255, 470, 590),
        (255, 505, 455),
        (255, 360, 320),
    ]
    let highlight = CGRect(x: 225 * s, y: 425 * s, width: 565 * s, height: 100 * s)
    ctx.addPath(rounded(ctx, highlight, 26 * s))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.fillPath()

    for (index, line) in lines.enumerated() {
        let bar = CGRect(x: line.0 * s, y: line.2 * s, width: line.1 * s, height: 58 * s)
        ctx.addPath(rounded(ctx, bar, 29 * s))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1,
                                 alpha: index == 1 ? 1.0 : 0.55))
        ctx.fillPath()
    }

    // Всплывающая панель над текстом — то, ради чего приложение и нужно.
    let pill = CGRect(x: 300 * s, y: 690 * s, width: 424 * s, height: 132 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 26 * s,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(rounded(ctx, pill, 66 * s))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()
    ctx.restoreGState()

    for i in 0..<3 {
        let cx = (382 + CGFloat(i) * 130) * s
        let dot = CGRect(x: cx - 26 * s, y: 730 * s, width: 52 * s, height: 52 * s)
        ctx.addEllipse(in: dot)
        ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.29, blue: 0.85, alpha: 1))
        ctx.fillPath()
    }

    return ctx.makeImage()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in sizes {
    guard let image = drawIcon(size: size) else { continue }
    let url = URL(fileURLWithPath: "\(out)/\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("нарисовано вариантов: \(sizes.count)")
