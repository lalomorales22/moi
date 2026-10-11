import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum QRCode {
    private static let context = CIContext()

    static func image(for value: String) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(value.utf8)
        generator.correctionLevel = "M"
        guard let code = generator.outputImage else { return nil }
        // Keep a four-module white quiet zone and render at an integer scale.
        let bounds = code.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: .white).cropped(to: bounds)
        let image = code.composited(over: background).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return context.createCGImage(image, from: image.extent)
    }
}
