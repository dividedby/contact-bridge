import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generated placeholder portraits for the demo: no image files, and each one different enough from the others that sync
/// tells them apart (a different arrangement and different colours).
enum DemoPhotos {
    private static let palettes: [(background: (Double, Double, Double), shape: (Double, Double, Double), accent: (Double, Double, Double))] = [
        ((0.93, 0.52, 0.20), (0.15, 0.25, 0.55), (1.00, 0.92, 0.70)),
        ((0.20, 0.55, 0.80), (0.95, 0.85, 0.30), (0.10, 0.20, 0.35)),
        ((0.55, 0.75, 0.35), (0.35, 0.15, 0.45), (0.98, 0.98, 0.90)),
        ((0.85, 0.30, 0.40), (0.95, 0.95, 0.95), (0.20, 0.10, 0.15)),
        ((0.25, 0.25, 0.30), (0.90, 0.65, 0.20), (0.45, 0.80, 0.85)),
        ((0.65, 0.45, 0.80), (0.20, 0.55, 0.45), (0.95, 0.80, 0.85)),
    ]

    /// A 240-px JPEG portrait placeholder: a background, a head-and-shoulders silhouette and a stripe, in the palette picked by
    /// `index`.
    static func portrait(_ index: Int) -> Data {
        let palette = palettes[index % palettes.count]
        let side = 240
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        guard let context else { return Data() }
        func fill(_ colour: (Double, Double, Double)) { context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1) }
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        fill(palette.background)
        context.fill(full)
        // A stripe whose slant depends on the index, so portraits with similar colours still differ in layout.
        fill(palette.accent)
        let stripe = CGFloat(20 + (index * 37) % 120)
        context.fill(CGRect(x: 0, y: stripe, width: CGFloat(side), height: 28))
        fill(palette.shape)
        context.fillEllipse(in: CGRect(x: 80, y: 105, width: 80, height: 80))
        context.fillEllipse(in: CGRect(x: 40, y: -50, width: 160, height: 130))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : Data()
    }
}
