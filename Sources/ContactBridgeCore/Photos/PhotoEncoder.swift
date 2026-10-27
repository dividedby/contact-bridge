import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoEncodingError: Error, Sendable, Hashable {
    /// The bytes are not a picture this machine can decode.
    case undecodable
    /// Even the smallest, lowest-quality version is over the byte cap.
    case tooLarge
}

/// Prepares a picture for Google: JPEG, longest side at most 1024 px, at most `maxBytes`, transparency flattened onto white
/// and every piece of metadata dropped (EXIF, GPS, TIFF and IPTC tags, embedded thumbnails). The EXIF orientation is applied
/// to the pixels rather than sent along, since the orientation tag is itself metadata.
public enum PhotoEncoder {
    public static let maxPixel = 1024
    public static let maxBytes = 2_000_000
    public static let startingQuality = 0.85
    private static let minimumQuality = 0.4
    private static let qualityStep = 0.15
    /// Below this the picture is too small to be worth shrinking further.
    private static let minimumSide = 128

    public static func jpegForGoogle(_ data: Data, maxBytes: Int = PhotoEncoder.maxBytes) throws -> Data {
        guard var image = PhotoImage.thumbnail(from: data, maxPixel: maxPixel) else { throw PhotoEncodingError.undecodable }
        while true {
            var quality = startingQuality
            while quality >= minimumQuality - 0.001 {
                let flat = try flattened(image)
                if let encoded = jpeg(flat, quality: quality), encoded.count <= maxBytes { return encoded }
                quality -= qualityStep
            }
            // Out of quality to give up: make the picture smaller instead.
            let side = max(image.width, image.height)
            guard side > minimumSide, let smaller = PhotoImage.thumbnail(from: data, maxPixel: max(minimumSide, side * 4 / 5)) else {
                throw PhotoEncodingError.tooLarge
            }
            image = smaller
        }
    }

    /// Opaque RGB with nothing underneath: fresh pixels carry no metadata.
    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw PhotoEncodingError.undecodable }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw PhotoEncodingError.undecodable }
        return result
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
