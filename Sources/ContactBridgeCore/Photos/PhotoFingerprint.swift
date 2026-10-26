import CoreGraphics
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
    /// `hash` and `colors` of the picture's centre square, for a picture that is not square: once iCloud has synced a
    /// contact photo, macOS hands back only a centre-square thumbnail of it, so the same picture can come back cropped.
    /// Nil for a square picture, and in fingerprints stored before this was added.
    public var centreHash: UInt64?
    public var centreColors: Data?

    public init(hash: UInt64, colors: Data, centreHash: UInt64? = nil, centreColors: Data? = nil) {
        self.hash = hash
        self.colors = colors
        self.centreHash = centreHash
        self.centreColors = centreColors
    }

    public func hammingDistance(to other: PhotoFingerprint) -> Int { (hash ^ other.hash).nonzeroBitCount }

    /// Mean absolute colour difference between the grids; infinite when they are not the same shape.
    public func colorDistance(to other: PhotoFingerprint) -> Double {
        guard colors.count == other.colors.count, !colors.isEmpty else { return .infinity }
        let total = zip(colors, other.colors).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(colors.count)
    }

    /// Differing hash bits still counted as the same picture when a centre square is compared: cutting the centre out of a
    /// differently scaled picture shifts it by a pixel or so, which moves the hash more than recompressing does.
    public static let centreHammingThreshold = 14
    /// The colour grid must agree much more closely to make up for it. Measured: the same picture stays under 1, unrelated
    /// ones were never closer than 15.
    public static let centreMaxColorDistance = 6.0

    /// The same picture when the wholes agree, or when either one's centre square agrees with the other (a centre-square
    /// thumbnail of the other, say). A change only at the edges of a wide photo is therefore not seen.
    public func isSimilar(
        to other: PhotoFingerprint, hammingThreshold: Int = PhotoFingerprint.hammingThreshold,
        maxColorDistance: Double = PhotoFingerprint.maxColorDistance
    ) -> Bool {
        if wholeMatches(other, hammingThreshold, maxColorDistance) { return true }
        return views.contains { mine in
            other.views.contains { theirs in
                (mine.isCentre || theirs.isCentre)
                    && mine.picture.wholeMatches(theirs.picture, Self.centreHammingThreshold, Self.centreMaxColorDistance)
            }
        }
    }

    private func wholeMatches(_ other: PhotoFingerprint, _ hammingThreshold: Int, _ maxColorDistance: Double) -> Bool {
        hammingDistance(to: other) <= hammingThreshold && colorDistance(to: other) <= maxColorDistance
    }

    /// The whole picture, then its centre square when stored.
    private var views: [(picture: PhotoFingerprint, isCentre: Bool)] {
        var views = [(PhotoFingerprint(hash: hash, colors: colors), false)]
        if let centreHash, let centreColors { views.append((PhotoFingerprint(hash: centreHash, colors: centreColors), true)) }
        return views
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
              var fingerprint = Self.fingerprint(of: image)
        else { return nil }
        // The centre is cut from a decode whose shorter side is `decodeSize`, so it has as much detail as a square picture.
        let longest = max(image.width, image.height), shortest = min(image.width, image.height)
        if longest != shortest, shortest > 0,
           let larger = PhotoImage.thumbnail(from: imageData, maxPixel: (Self.decodeSize * longest + shortest - 1) / shortest),
           let square = larger.cropping(to: Self.centreSquare(of: larger)),
           let centre = Self.fingerprint(of: square) {
            fingerprint.centreHash = centre.hash
            fingerprint.centreColors = centre.colors
        }
        return fingerprint
    }

    private static func centreSquare(of image: CGImage) -> CGRect {
        let side = min(image.width, image.height)
        return CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
    }

    private static func fingerprint(of image: CGImage) -> PhotoFingerprint? {
        guard let gradient = PhotoImage.pixels(of: image, width: hashColumns, height: hashRows),
              let grid = PhotoImage.pixels(of: image, width: PhotoFingerprint.gridSide, height: PhotoFingerprint.gridSide)
        else { return nil }

        func luminance(_ column: Int, _ row: Int) -> Double {
            let offset = (row * hashColumns + column) * 4
            return 0.299 * Double(gradient[offset]) + 0.587 * Double(gradient[offset + 1]) + 0.114 * Double(gradient[offset + 2])
        }
        var hash: UInt64 = 0
        for row in 0..<hashRows {
            for column in 0..<(hashColumns - 1) {
                hash <<= 1
                if luminance(column, row) > luminance(column + 1, row) + luminanceMargin { hash |= 1 }
            }
        }

        var colors = Data()
        for cell in 0..<(PhotoFingerprint.gridSide * PhotoFingerprint.gridSide) {
            colors.append(contentsOf: grid[(cell * 4)..<(cell * 4 + 3)])
        }
        return PhotoFingerprint(hash: hash, colors: colors)
    }
}
