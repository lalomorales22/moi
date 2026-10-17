import AppKit
import ImageIO
import UniformTypeIdentifiers

// Render into an opaque RGB context: App Store Connect rejects icons with an alpha channel.
func makeIcon(pixels: Int, path: String) throws {
    let context = CGContext(data: nil, width: pixels, height: pixels,
                            bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let mint = CGColor(red: 0.63, green: 0.97, blue: 0.65, alpha: 1)
    let ink = CGColor(red: 0.055, green: 0.07, blue: 0.075, alpha: 1)
    context.setFillColor(mint)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    func rounded(_ rect: CGRect, radius: CGFloat, color: CGColor) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }
    rounded(CGRect(x: 320, y: 390, width: 384, height: 466), radius: 75, color: ink)
    rounded(CGRect(x: 348, y: 420, width: 328, height: 400), radius: 50, color: mint)
    rounded(CGRect(x: 434, y: 791, width: 156, height: 40), radius: 20, color: ink)
    for (index, height) in [80, 156, 220, 124, 66].enumerated() {
        rounded(CGRect(x: 389 + index * 50, y: 600 - height / 2, width: 30, height: height), radius: 15, color: ink)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let text = "moi" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 238, weight: .black),
        .foregroundColor: NSColor(cgColor: ink)!, .kern: -14
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: 100), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
}

// Xcode 14+ single-size icon: actool derives every device size from this 1024×1024 image.
try makeIcon(pixels: 1024, path: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
