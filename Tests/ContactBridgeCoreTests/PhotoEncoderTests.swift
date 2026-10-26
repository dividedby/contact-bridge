import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ContactBridgeCore

struct PhotoEncoderTests {
    private let fingerprinter = ImageIOPhotoFingerprinter()

    @Test("A large photo is scaled so its longest side is 1024 and comes out as JPEG")
    func scalesDown() throws {
        let data = PhotoTestImages.jpeg(PhotoTestImages.scene(seed: 1, width: 3000, height: 2000))
        let output = try PhotoEncoder.jpegForGoogle(data)
        let size = PhotoTestImages.pixelSize(of: output)
        #expect(size.width == 1024 && abs(size.height - 683) <= 1)
        #expect(Array(output.prefix(3)) == [0xFF, 0xD8, 0xFF])
        // Still the same picture.
        #expect(try #require(fingerprinter.fingerprint(of: output)).isSimilar(to: try #require(fingerprinter.fingerprint(of: data))))
    }

    @Test("A small photo is not enlarged")
    func keepsSmall() throws {
        let output = try PhotoEncoder.jpegForGoogle(PhotoTestImages.jpeg(PhotoTestImages.scene(seed: 2, width: 200, height: 120)))
        let size = PhotoTestImages.pixelSize(of: output)
        #expect(size.width == 200 && size.height == 120)
    }

    @Test("Transparency is flattened onto white")
    func flattensAlpha() throws {
        let transparent = PhotoTestImages.image(width: 100, height: 100) { context in
            PhotoTestImages.fill(context, .red, CGRect(x: 0, y: 0, width: 50, height: 100))
        }
        let png = try #require(PhotoTestImages.encode(transparent, as: .png))
        let output = try PhotoEncoder.jpegForGoogle(png)
        let white = try #require(PhotoTestImages.colour(in: output, x: 0.9, y: 0.5))
        let red = try #require(PhotoTestImages.colour(in: output, x: 0.1, y: 0.5))
        #expect(white.r > 245 && white.g > 245 && white.b > 245)
        #expect(red.r > 230 && red.g < 30 && red.b < 30)
        #expect(PhotoTestImages.properties(of: output)[kCGImagePropertyHasAlpha as String] as? Bool != true)
    }

    @Test("EXIF, GPS and other metadata are not carried into the output")
    func stripsMetadata() throws {
        let source = PhotoTestImages.scene(seed: 3, width: 400, height: 300)
        let tagged = try #require(PhotoTestImages.encode(source, as: .jpeg, extra: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private", kCGImagePropertyExifDateTimeOriginal: "2020:01:01 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera Co", kCGImagePropertyTIFFModel: "X100"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "a caption"],
        ]))
        // The fixture really carries what we claim to strip.
        let before = PhotoTestImages.properties(of: tagged)
        #expect(before[kCGImagePropertyGPSDictionary as String] != nil && before[kCGImagePropertyExifDictionary as String] != nil)

        let after = PhotoTestImages.properties(of: try PhotoEncoder.jpegForGoogle(tagged))
        #expect(after[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(after[kCGImagePropertyIPTCDictionary as String] == nil)
        let exif = after[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifUserComment as String] == nil && exif[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        let tiff = after[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFMake as String] == nil && tiff[kCGImagePropertyTIFFModel as String] == nil)
        #expect(after[kCGImagePropertyOrientation as String] == nil || after[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(!String(decoding: try PhotoEncoder.jpegForGoogle(tagged), as: UTF8.self).contains("Camera Co"))
    }

    @Test("EXIF orientation is baked into the pixels instead of being sent along")
    func bakesOrientation() throws {
        let data = PhotoTestImages.jpeg(PhotoTestImages.split(.red, .blue, width: 240, height: 120), orientation: 6)
        let output = try PhotoEncoder.jpegForGoogle(data)
        let size = PhotoTestImages.pixelSize(of: output)
        #expect(size.width == 120 && size.height == 240)
        let top = try #require(PhotoTestImages.colour(in: output, x: 0.5, y: 0.1))
        let bottom = try #require(PhotoTestImages.colour(in: output, x: 0.5, y: 0.9))
        #expect(top.r > 200 && top.b < 60 && bottom.b > 200 && bottom.r < 60)
        let orientation = PhotoTestImages.properties(of: output)[kCGImagePropertyOrientation as String] as? Int
        #expect(orientation == nil || orientation == 1)
    }

    @Test("PNG, TIFF and HEIC inputs all become JPEG")
    func formats() throws {
        let scene = PhotoTestImages.scene(seed: 4)
        for type in [UTType.png, .tiff, .heic] {
            let input = try #require(PhotoTestImages.encode(scene, as: type), "cannot encode \(type.identifier)")
            let output = try PhotoEncoder.jpegForGoogle(input)
            #expect(Array(output.prefix(3)) == [0xFF, 0xD8, 0xFF], "\(type.identifier)")
        }
    }

    @Test("Output stays within the byte cap by lowering quality, then size")
    func byteCap() throws {
        let noisy = PhotoTestImages.jpeg(PhotoTestImages.noise(seed: 7, width: 1500, height: 1500), quality: 1)
        let normal = try PhotoEncoder.jpegForGoogle(noisy)
        #expect(normal.count <= PhotoEncoder.maxBytes)
        #expect(PhotoEncoder.maxBytes == 2_000_000)
        let capped = try PhotoEncoder.jpegForGoogle(noisy, maxBytes: 150_000)
        #expect(capped.count <= 150_000)
        let size = PhotoTestImages.pixelSize(of: capped)
        #expect(max(size.width, size.height) <= 1024 && max(size.width, size.height) >= 128)
    }

    @Test("A cap nothing can meet is an error, not an oversized photo")
    func impossibleCap() {
        let noisy = PhotoTestImages.jpeg(PhotoTestImages.noise(seed: 8, width: 600, height: 600))
        #expect(throws: PhotoEncodingError.tooLarge) { try PhotoEncoder.jpegForGoogle(noisy, maxBytes: 100) }
    }

    @Test("Bytes that are not an image are rejected")
    func notAnImage() {
        #expect(throws: PhotoEncodingError.undecodable) { try PhotoEncoder.jpegForGoogle(Data("nope".utf8)) }
        #expect(throws: PhotoEncodingError.undecodable) { try PhotoEncoder.jpegForGoogle(Data()) }
    }

    @Test("The errors tell the user what happened")
    func descriptions() {
        #expect(PhotoEncodingError.undecodable.localizedDescription.contains("photo"))
        #expect(PhotoEncodingError.tooLarge.localizedDescription.contains("too large"))
    }
}
