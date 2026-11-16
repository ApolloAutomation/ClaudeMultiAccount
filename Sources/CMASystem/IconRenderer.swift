import AppKit
import CMACore
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum IconRendererError: Error, Equatable {
    case renderFailed
    case encodeFailed
}

/// Profile app icon: squircle on the macOS 824/1024 grid, vertical gradient of the profile color, white heavy letter.
public enum IconRenderer {
    public static let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// sRGB components (top, bottom) of the gradient for a profile color.
    public static func gradient(_ color: ProfileColor) -> (top: (CGFloat, CGFloat, CGFloat), bottom: (CGFloat, CGFloat, CGFloat)) {
        let base: (CGFloat, CGFloat, CGFloat) = switch color {
        case .orange: (0.85, 0.42, 0.29)
        case .blue: (0.04, 0.48, 1.00)
        case .green: (0.20, 0.70, 0.35)
        case .purple: (0.62, 0.32, 0.87)
        case .pink: (1.00, 0.28, 0.48)
        case .red: (0.95, 0.23, 0.21)
        case .teal: (0.19, 0.69, 0.78)
        case .gray: (0.50, 0.50, 0.54)
        }
        func mix(_ c: CGFloat, _ t: CGFloat, _ f: CGFloat) -> CGFloat { c + (t - c) * f }
        let top = (mix(base.0, 1, 0.22), mix(base.1, 1, 0.22), mix(base.2, 1, 0.22))
        let bottom = (mix(base.0, 0, 0.12), mix(base.1, 0, 0.12), mix(base.2, 0, 0.12))
        return (top, bottom)
    }

    public static func render(letter: String, color: ProfileColor, size: Int) -> CGImage? {
        guard size > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        let scale = s / 1024
        let rect = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let radius = 185.4 * scale
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Soft drop shadow like system icons.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        let g = gradient(color)
        let colors = [CGColor(srgbRed: g.top.0, green: g.top.1, blue: g.top.2, alpha: 1),
                      CGColor(srgbRed: g.bottom.0, green: g.bottom.1, blue: g.bottom.2, alpha: 1)] as CFArray
        guard let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        ctx.restoreGState()

        let ch = Slug.badgeLetter(letter)
        if !ch.isEmpty {
            let font = NSFont.systemFont(ofSize: 520 * scale, weight: .heavy) as CTFont
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: ch, attributes: attrs))
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: rect.midX - b.width / 2 - b.minX, y: rect.midY - b.height / 2 - b.minY)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    public static func pngData(letter: String, color: ProfileColor, size: Int) throws -> Data {
        guard let img = render(letter: letter, color: color, size: size) else { throw IconRendererError.renderFailed }
        return try encode([img], type: UTType.png.identifier as CFString)
    }

    public static func icnsData(letter: String, color: ProfileColor) throws -> Data {
        let images = try icnsSizes.map { size -> CGImage in
            guard let i = render(letter: letter, color: color, size: size) else { throw IconRendererError.renderFailed }
            return i
        }
        return try encode(images, type: "com.apple.icns" as CFString)
    }

    public static func writeICNS(letter: String, color: ProfileColor, to url: URL) throws {
        try AtomicFile.write(icnsData(letter: letter, color: color), to: url)
    }

    static func encode(_ images: [CGImage], type: CFString) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type, images.count, nil) else {
            throw IconRendererError.encodeFailed
        }
        for i in images { CGImageDestinationAddImage(dest, i, nil) }
        guard CGImageDestinationFinalize(dest) else { throw IconRendererError.encodeFailed }
        return data as Data
    }
}
