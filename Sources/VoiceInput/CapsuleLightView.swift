import AppKit
import CoreImage
import QuartzCore

// Local reflections are composed above the glass and below the sharp content.
// This also keeps the approved lighting visible while a new backdrop is loading.
final class CapsuleLightView: NSView {
    private var barFrames: [CGRect] = []
    private var textRect = CGRect.zero
    private var power: CGFloat = 0.28
    private var reflection: CGImage?
    private var reflectionSize = CGSize.zero
    private var textKey = ""
    private var lastDisplay: CFTimeInterval = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let glowImage: CGImage = {
        let size = 96
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor(calibratedRed: 245.0 / 255, green: 248.0 / 255, blue: 1, alpha: 1).cgColor,
                     NSColor(calibratedRed: 245.0 / 255, green: 248.0 / 255, blue: 1, alpha: 0.48).cgColor,
                     NSColor.clear.cgColor] as CFArray, locations: [0, 0.4, 1])!
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 48, y: 48), startRadius: 0,
                               endCenter: CGPoint(x: 48, y: 48), endRadius: 48, options: [])
        return ctx.makeImage()!
    }()

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(bars: [CGRect], text: String, frame: CGRect, font: NSFont, energy: CGFloat) {
        barFrames = bars
        textRect = CGRect(x: frame.minX + 2, y: frame.minY,
                          width: min(frame.width - 4, (text as NSString).size(withAttributes: [.font: font]).width),
                          height: frame.height)
        power = 0.28 + 0.72 * energy
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(text)|\(font.pointSize)|\(textRect.width)|\(scale)"
        if key != textKey {
            textKey = key
            makeReflection(text: text, font: font, scale: scale)
        }
        let now = CACurrentMediaTime()
        if now - lastDisplay >= 1.0 / 30 {
            lastDisplay = now
            needsDisplay = true
        }
    }

    private func makeReflection(text: String, font: NSFont, scale: CGFloat) {
        reflection = nil
        guard textRect.width > 0 else { return }
        // Cache only the glyphs, never screen pixels. Blur after flattening the
        // mirror image so its softness stays constant in screen coordinates.
        let padding: CGFloat = 12
        let size = CGSize(width: ceil(textRect.width) + padding * 2,
                          height: ceil(font.ascender - font.descender + font.leading) + padding * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: scale, y: scale)
        (text as NSString).draw(with: CGRect(x: padding, y: padding,
            width: textRect.width, height: size.height - padding * 2),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return }
        let mirrored = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 1, y: -0.27))
        let extent = mirrored.extent.insetBy(dx: -3 * scale, dy: -3 * scale)
        let blurred = mirrored.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.6 * scale])
        reflection = context.createCGImage(blurred, from: extent)
        reflectionSize = CGSize(width: extent.width / scale, height: extent.height / scale)
    }

    private func glow(_ ctx: CGContext, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat, alpha: CGFloat) {
        guard rx > 0, ry > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.draw(Self.glowImage, in: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !barFrames.isEmpty else { return }
        let radius = bounds.height / 2, cy = bounds.midY
        let waveX = (barFrames.first!.midX + barFrames.last!.midX) / 2
        let textCenter = textRect.midX, textWidth = textRect.width
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        glow(ctx, x: waveX, y: cy, rx: 48, ry: 26, alpha: 0.12 * power)
        glow(ctx, x: waveX + 1, y: bounds.maxY - 4, rx: 58, ry: 9, alpha: 0.20 * power)
        glow(ctx, x: waveX + 7, y: bounds.minY + 4, rx: 52, ry: 8, alpha: 0.14 * power)
        // Each source has a compressed, softly focused image on the inner walls.
        for bar in barFrames {
            let x = waveX + (bar.midX - waveX) * 1.45
            let rx = bar.width * 1.45 / 2 + 2.6, ry = bar.height * 0.24 / 2 + 2.6
            glow(ctx, x: x, y: bounds.maxY - 5, rx: rx, ry: ry, alpha: 0.16 * power)
            glow(ctx, x: x, y: bounds.minY + 5, rx: rx, ry: ry, alpha: 0.10 * power)
        }
        glow(ctx, x: textCenter, y: cy, rx: textWidth * 0.63, ry: 22, alpha: 0.064)
        glow(ctx, x: textCenter + 2, y: bounds.maxY - 5, rx: textWidth * 0.66, ry: 9, alpha: 0.095)
        glow(ctx, x: textCenter - 2, y: bounds.minY + 5, rx: textWidth * 0.63, ry: 8, alpha: 0.072)
        if let reflection {
            for (y, stretch, alpha) in [(bounds.maxY - 6, 1.08, 0.17), (bounds.minY + 6, 1.04, 0.13)] {
                let size = CGSize(width: reflectionSize.width * stretch, height: reflectionSize.height)
                ctx.saveGState()
                ctx.setAlpha(alpha)
                ctx.draw(reflection, in: CGRect(x: textCenter - size.width / 2, y: y - size.height / 2,
                                                width: size.width, height: size.height))
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }
}
