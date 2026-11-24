import AppKit

/// An action's icon: an SF Symbol by name, or — for the few names below — an
/// app's own mark, drawn as a template so it takes the bar's tint like the
/// symbols beside it.
enum ActionIcon {
    /// DeepL's speech bubble with the three linked dots, taken from the app.
    static let deepL = "deepl"

    static func image(_ name: String, pointSize: CGFloat, description: String? = nil) -> NSImage? {
        if name == deepL, let mark = deepLMark {
            let height = pointSize * 1.3
            let size = NSSize(width: height * mark.size.width / mark.size.height, height: height)
            let image = NSImage(size: size, flipped: false) { rect in
                mark.draw(in: rect)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = description
            return image
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
    }

    static func exists(_ name: String) -> Bool {
        name == deepL ? deepLMark != nil : NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The app icon is a light tile with a dark bubble on it and light dots
    /// inside the bubble. The dark is the mark: it is kept as ink, the tile and
    /// the dots become holes, and what is left is cropped to the bubble.
    private static let deepLMark: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DeepLApp.bundleID) else { return nil }
        // From the bundle's own file: the icon the system hands out follows
        // the appearance, and in dark mode its tile is dark and its bubble light.
        let file = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        let iconURL = url.appendingPathComponent("Contents/Resources")
            .appendingPathComponent(file.hasSuffix(".icns") ? file : file + ".icns")
        guard let icon = NSImage(contentsOf: iconURL) else { return nil }
        let side = 256
        guard let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: source) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = source.bitmapData else { return nil }

        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side {
                let p = pixels + (y * side + x) * 4
                let alpha = Double(p[3]) / 255
                // Premultiplied: back to the colour before judging its light.
                let lum = alpha > 0
                    ? (0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])) / 255 / alpha
                    : 1
                // Soft across the edge, so the outline stays smooth.
                let ink = max(0, min(1, (0.48 - lum) / 0.16)) * alpha
                let value = UInt8(ink * 255)
                p[0] = 0; p[1] = 0; p[2] = 0; p[3] = value
                if value > 128 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY,
              let whole = source.cgImage,
              let cropped = whole.cropping(to: CGRect(x: minX, y: minY,
                                                      width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }()
}
