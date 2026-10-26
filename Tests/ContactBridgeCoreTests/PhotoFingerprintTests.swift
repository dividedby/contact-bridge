import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ContactBridgeCore

struct PhotoFingerprintTests {
    private let fingerprinter = ImageIOPhotoFingerprinter()

    private func fingerprint(_ data: Data) throws -> PhotoFingerprint {
        try #require(fingerprinter.fingerprint(of: data))
    }

    @Test("A recompressed, rescaled copy of a photo is similar to the original")
    func recompressed() throws {
        let scene = PhotoTestImages.scene(seed: 1, width: 600, height: 600)
        let original = try fingerprint(PhotoTestImages.jpeg(scene, quality: 0.95))
        let recompressed = try fingerprint(PhotoTestImages.jpeg(scene, quality: 0.3))
        let smaller = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.scaled(scene, width: 128, height: 128)))
        #expect(original.isSimilar(to: recompressed))
        #expect(original.isSimilar(to: smaller))
        #expect(smaller.isSimilar(to: original))
    }

    @Test("Different photos are not similar")
    func different() throws {
        let prints = try (1...12).map { try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.scene(seed: UInt64($0)))) }
        for (index, print) in prints.enumerated() {
            for other in prints[(index + 1)...] { #expect(!print.isSimilar(to: other)) }
        }
    }

    @Test("Solid colours: the same one survives recompression, another one does not match")
    func solidColours() throws {
        let red = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.solid(.red), quality: 0.9))
        let redAgain = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.solid(.red, width: 90, height: 90), quality: 0.4))
        let blue = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.solid(.blue)))
        let white = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.solid(.white)))
        let black = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.solid(.black)))
        #expect(red.isSimilar(to: redAgain))
        #expect(!red.isSimilar(to: blue))
        #expect(!white.isSimilar(to: black))
        // No edges at all, so the hash cannot tell these apart; the colour grid does.
        #expect(red.hash == blue.hash && red.hash == white.hash)
    }

    @Test("The same colours laid out differently are not similar")
    func layout() throws {
        let sideBySide = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.split(.red, .blue)))
        let stacked = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.split(.red, .blue, stacked: true)))
        let swapped = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.split(.blue, .red)))
        #expect(!sideBySide.isSimilar(to: stacked))
        #expect(!sideBySide.isSimilar(to: swapped))
        #expect(sideBySide.isSimilar(to: sideBySide))
    }

    @Test("EXIF orientation is applied before fingerprinting")
    func orientation() throws {
        // Pixels are red left, blue right; orientation 6 displays them rotated a quarter turn clockwise: red on top.
        let raw = PhotoTestImages.split(.red, .blue, width: 240, height: 120)
        let rotated = try fingerprint(PhotoTestImages.jpeg(raw, orientation: 6))
        let redOnTop = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.split(.red, .blue, width: 120, height: 240, stacked: true)))
        let unrotated = try fingerprint(PhotoTestImages.jpeg(raw))
        #expect(rotated.isSimilar(to: redOnTop))
        #expect(!rotated.isSimilar(to: unrotated))
    }

    @Test("PNG and TIFF decode too, and a transparent background counts as white")
    func otherFormats() throws {
        let scene = PhotoTestImages.scene(seed: 4)
        let jpeg = try fingerprint(PhotoTestImages.jpeg(scene))
        let png = try fingerprint(try #require(PhotoTestImages.encode(scene, as: .png)))
        let tiff = try fingerprint(try #require(PhotoTestImages.encode(scene, as: .tiff)))
        #expect(jpeg.isSimilar(to: png) && jpeg.isSimilar(to: tiff))

        let transparent = PhotoTestImages.solid(PhotoTestImages.RGB(r: 0, g: 0, b: 0, a: 0))
        let white = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.solid(.white)))
        #expect(try fingerprint(try #require(PhotoTestImages.encode(transparent, as: .png))).isSimilar(to: white))
    }

    @Test("HEIC decodes and matches the same picture as a JPEG")
    func heic() throws {
        let scene = PhotoTestImages.scene(seed: 5)
        let heic = try #require(PhotoTestImages.encode(scene, as: .heic, quality: 0.8), "this machine cannot encode HEIC")
        #expect(try fingerprint(heic).isSimilar(to: try fingerprint(PhotoTestImages.jpeg(scene))))
        let other = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.scene(seed: 6)))
        #expect(!(try fingerprint(heic)).isSimilar(to: other))
    }

    @Test("Bytes that are not an image have no fingerprint")
    func notAnImage() {
        #expect(fingerprinter.fingerprint(of: Data("not an image".utf8)) == nil)
        #expect(fingerprinter.fingerprint(of: Data()) == nil)
        #expect(fingerprinter.fingerprint(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == nil)
    }

    @Test("The threshold is a parameter, so it can be retuned from stored hashes")
    func threshold() {
        let a = PhotoFingerprint(hash: 0, colors: Data(repeating: 100, count: 48))
        let near = PhotoFingerprint(hash: 0b111111, colors: Data(repeating: 100, count: 48))
        let far = PhotoFingerprint(hash: 0b1111111, colors: Data(repeating: 100, count: 48))
        #expect(a.hammingDistance(to: near) == 6 && a.hammingDistance(to: far) == 7)
        #expect(a.isSimilar(to: near) && !a.isSimilar(to: far))
        #expect(a.isSimilar(to: far, hammingThreshold: 7))
        #expect(!a.isSimilar(to: near, hammingThreshold: 5))
        #expect(PhotoFingerprint.hammingThreshold == 6)
    }

    @Test("Fingerprints of different grid sizes never match")
    func gridMismatch() {
        let a = PhotoFingerprint(hash: 0, colors: Data(repeating: 0, count: 48))
        let b = PhotoFingerprint(hash: 0, colors: Data(repeating: 0, count: 12))
        #expect(!a.isSimilar(to: b))
    }

    @Test("A fingerprint survives JSON, including a hash with the top bit set")
    func codable() throws {
        let original = PhotoFingerprint(hash: UInt64.max, colors: Data((0..<48).map { UInt8($0 * 5) }))
        let decoded = try JSONDecoder().decode(PhotoFingerprint.self, from: JSONEncoder().encode(original))
        #expect(decoded == original && decoded.hash == UInt64.max)
        let real = try fingerprint(PhotoTestImages.jpeg(PhotoTestImages.scene(seed: 9)))
        #expect(try JSONDecoder().decode(PhotoFingerprint.self, from: JSONEncoder().encode(real)) == real)
    }
}
