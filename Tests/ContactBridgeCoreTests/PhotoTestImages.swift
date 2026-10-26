import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ContactBridgeCore

/// Generated images for the photo tests: no fixture files, and every case builds exactly the pixels it needs.
enum PhotoTestImages {
    struct RGB {
        var r: Double, g: Double, b: Double, a: Double = 1
        static let red = RGB(r: 1, g: 0, b: 0)
        static let blue = RGB(r: 0, g: 0, b: 1)
        static let green = RGB(r: 0, g: 0.7, b: 0)
        static let white = RGB(r: 1, g: 1, b: 1)
        static let black = RGB(r: 0, g: 0, b: 0)
    }

    /// A bitmap drawn by `draw` over a transparent background, in a top-left-origin coordinate space.
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()!
    }

    static func fill(_ context: CGContext, _ colour: RGB, _ rect: CGRect) {
        context.setFillColor(red: colour.r, green: colour.g, blue: colour.b, alpha: colour.a)
        context.fill(rect)
    }

    static func solid(_ colour: RGB, width: Int = 200, height: Int = 200) -> CGImage {
        image(width: width, height: height) { fill($0, colour, CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    /// Two colours side by side (`vertical: false`) or stacked.
    static func split(_ first: RGB, _ second: RGB, width: Int = 200, height: Int = 200, stacked: Bool = false) -> CGImage {
        image(width: width, height: height) { context in
            let w = CGFloat(width), h = CGFloat(height)
            if stacked {
                fill(context, first, CGRect(x: 0, y: 0, width: w, height: h / 2))
                fill(context, second, CGRect(x: 0, y: h / 2, width: w, height: h / 2))
            } else {
                fill(context, first, CGRect(x: 0, y: 0, width: w / 2, height: h))
                fill(context, second, CGRect(x: w / 2, y: 0, width: w / 2, height: h))
            }
        }
    }

    /// A smooth diagonal gradient with a few shapes: has structure at every scale, like a photo.
    static func scene(seed: UInt64, width: Int = 300, height: Int = 300) -> CGImage {
        var generator = SeededGenerator(seed: seed)
        return image(width: width, height: height) { context in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let colours = (0..<2).map { _ in
                [CGFloat.random(in: 0...1, using: &generator), .random(in: 0...1, using: &generator), .random(in: 0...1, using: &generator), 1]
            }
            let gradient = CGGradient(colorSpace: space, colorComponents: colours.flatMap { $0 }, locations: [0, 1], count: 2)!
            context.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: []
            )
            for _ in 0..<6 {
                let colour = RGB(
                    r: .random(in: 0...1, using: &generator), g: .random(in: 0...1, using: &generator),
                    b: .random(in: 0...1, using: &generator)
                )
                let size = CGFloat.random(in: 30...120, using: &generator)
                fill(context, colour, CGRect(
                    x: .random(in: 0...(CGFloat(width) - size), using: &generator),
                    y: .random(in: 0...(CGFloat(height) - size), using: &generator), width: size, height: size
                ))
            }
        }
    }

    static func scaled(_ source: CGImage, width: Int, height: Int) -> CGImage {
        image(width: width, height: height) { context in
            context.interpolationQuality = .high
            // The context is flipped to a top-left origin; flip back so the picture is not drawn upside down.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Per-pixel noise: incompressible, so it makes large files.
    static func noise(seed: UInt64, width: Int, height: Int) -> CGImage {
        var generator = SeededGenerator(seed: seed)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = .random(in: 0...255, using: &generator)
            bytes[index * 4 + 1] = .random(in: 0...255, using: &generator)
            bytes[index * 4 + 2] = .random(in: 0...255, using: &generator)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Encodes with ImageIO; nil when this machine cannot encode the type.
    static func encode(
        _ image: CGImage, as type: UTType = .jpeg, quality: Double = 0.9, orientation: Int? = nil, extra: [CFString: Any] = [:]
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = extra
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.9, orientation: Int? = nil) -> Data {
        encode(image, as: .jpeg, quality: quality, orientation: orientation)!
    }

    /// Decodes bytes back to pixels, ignoring orientation, plus the container's metadata dictionaries.
    static func properties(of data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return properties
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        let properties = properties(of: data)
        return (properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0, properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
    }

    /// The colour at a fraction (0..<1, from the top left) of the decoded image as it displays (orientation applied), 0...255.
    static func colour(in data: Data, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
        guard let image = PhotoImage.thumbnail(from: data, maxPixel: 256) else { return nil }
        let side = 20
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let offset = (min(Int(y * Double(side)), side - 1) * side + min(Int(x * Double(side)), side - 1)) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }
}
