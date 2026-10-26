import Foundation

/// A compact look-alike key for a picture: a 64-bit difference hash (does each pixel of a 9x8 grayscale version get darker
/// to the right) plus the mean colour of each cell of a 4x4 grid. The hash alone cannot tell two flat colours apart and the
/// colours alone cannot tell two arrangements apart, so two photos are the same picture only when both agree. Recompressing,
/// rescaling or re-encoding a photo keeps it similar to itself; an unrelated photo is not.
///
/// Stored in baselines, so the format is stable; `hammingThreshold` is a parameter of the comparison and can be retuned
/// without recomputing anything.
public struct PhotoFingerprint: Sendable, Hashable, Codable {
    /// Cells per side of the colour grid.
    public static let gridSide = 4
    /// Differing hash bits still counted as the same picture.
    public static let hammingThreshold = 6
    /// Mean absolute difference over the colour grid (0...255 per channel) still counted as the same picture.
    public static let maxColorDistance = 24.0

    /// Row-major bits of the 8x8 horizontal-gradient comparison.
    public var hash: UInt64
    /// `gridSide` x `gridSide` cells, row-major, three bytes (R, G, B) each.
    public var colors: Data

    public init(hash: UInt64, colors: Data) {
        self.hash = hash
        self.colors = colors
    }

    public func hammingDistance(to other: PhotoFingerprint) -> Int { (hash ^ other.hash).nonzeroBitCount }

    /// Mean absolute colour difference between the grids; infinite when they are not the same shape.
    public func colorDistance(to other: PhotoFingerprint) -> Double {
        guard colors.count == other.colors.count, !colors.isEmpty else { return .infinity }
        let total = zip(colors, other.colors).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(colors.count)
    }

    public func isSimilar(
        to other: PhotoFingerprint, hammingThreshold: Int = PhotoFingerprint.hammingThreshold,
        maxColorDistance: Double = PhotoFingerprint.maxColorDistance
    ) -> Bool {
        hammingDistance(to: other) <= hammingThreshold && colorDistance(to: other) <= maxColorDistance
    }
}

/// Turns picture bytes into a `PhotoFingerprint`. A protocol so the reconciler's tests can script fingerprints.
public protocol PhotoFingerprinting: Sendable {
    /// Nil when the bytes are not a picture this machine can decode.
    func fingerprint(of imageData: Data) -> PhotoFingerprint?
}

/// The real implementation: ImageIO decodes (JPEG, PNG, TIFF, HEIC, ...), applying EXIF orientation, at 64 px.
public struct ImageIOPhotoFingerprinter: PhotoFingerprinting {
    private static let decodeSize = 64
    private static let hashColumns = 9
    private static let hashRows = 8
    /// Neighbouring luminances closer than this count as equal, so compression noise on flat areas cannot flip bits.
    private static let luminanceMargin = 2.0

    public init() {}

    public func fingerprint(of imageData: Data) -> PhotoFingerprint? {
        guard let image = PhotoImage.thumbnail(from: imageData, maxPixel: Self.decodeSize),
              let gradient = PhotoImage.pixels(of: image, width: Self.hashColumns, height: Self.hashRows),
              let grid = PhotoImage.pixels(of: image, width: PhotoFingerprint.gridSide, height: PhotoFingerprint.gridSide)
        else { return nil }

        func luminance(_ column: Int, _ row: Int) -> Double {
            let offset = (row * Self.hashColumns + column) * 4
            return 0.299 * Double(gradient[offset]) + 0.587 * Double(gradient[offset + 1]) + 0.114 * Double(gradient[offset + 2])
        }
        var hash: UInt64 = 0
        for row in 0..<Self.hashRows {
            for column in 0..<(Self.hashColumns - 1) {
                hash <<= 1
                if luminance(column, row) > luminance(column + 1, row) + Self.luminanceMargin { hash |= 1 }
            }
        }

        var colors = Data()
        for cell in 0..<(PhotoFingerprint.gridSide * PhotoFingerprint.gridSide) {
            colors.append(contentsOf: grid[(cell * 4)..<(cell * 4 + 3)])
        }
        return PhotoFingerprint(hash: hash, colors: colors)
    }
}
