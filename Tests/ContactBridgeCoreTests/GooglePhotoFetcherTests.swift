import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct GooglePhotoFetcherTests {
    /// Records the requests it is given and answers with a fixed result.
    private final class RecordingTransport: HTTPTransport, Sendable {
        private let seen = Mutex<[URLRequest]>([])
        private let result: Mutex<HTTPResult>

        init(_ result: HTTPResult) { self.result = Mutex(result) }

        var requests: [URLRequest] { seen.withLock { $0 } }

        func send(_ request: URLRequest) async throws -> HTTPResult {
            seen.withLock { $0.append(request) }
            return result.withLock { $0 }
        }
    }

    private let image = PhotoTestImages.jpeg(PhotoTestImages.scene(seed: 3, width: 128, height: 128))
    private let url = URL(string: "https://lh3.googleusercontent.com/contacts/AEmZk1=s128")!

    private func fetcher(_ result: HTTPResult) -> (URLSessionGooglePhotoFetcher, RecordingTransport) {
        let transport = RecordingTransport(result)
        return (URLSessionGooglePhotoFetcher(transport: transport), transport)
    }

    @Test("A photo is fetched with a bare GET: no authorization, no cookies, a 20 second timeout")
    func requestShape() async throws {
        let (fetcher, transport) = fetcher(HTTPResult(status: 200, body: image))
        #expect(try await fetcher.fetch(url) == image)

        let request = try #require(transport.requests.first)
        #expect(request.url == url && request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.timeoutInterval == 20 && request.httpShouldHandleCookies == false)
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers.keys.allSatisfy { $0.caseInsensitiveCompare("Accept") == .orderedSame })
        #expect(headers["Authorization"] == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(URLSessionGooglePhotoFetcher.timeout == 20 && URLSessionGooglePhotoFetcher.maxBytes == 10_000_000)
    }

    @Test("Only https addresses on a googleusercontent.com host are fetched; nothing is sent for the others")
    func allowedAddresses() async throws {
        let allowed = [
            "https://lh3.googleusercontent.com/a/x=s64", "https://lh4.googleusercontent.com/x", "https://LH3.GoogleUserContent.com/x",
            "https://a.b.googleusercontent.com/x", "https://lh3.googleusercontent.com:443/x",
        ]
        let refused = [
            "http://lh3.googleusercontent.com/x", "ftp://lh3.googleusercontent.com/x", "file:///tmp/x.jpg",
            "https://googleusercontent.com/x", "https://example.com/x", "https://evil.com/.googleusercontent.com/x",
            "https://lh3.googleusercontent.com.evil.com/x", "https://evilgoogleusercontent.com/x", "https://lh3.googleusercontent.com@evil.com/x",
            "https://user:pw@lh3.googleusercontent.com/x", "https://lh3.googleusercontent.com:8443/x", "https://lh3.google.com/x",
            "https://127.0.0.1/x", "https://localhost/x",
        ]
        let (fetcher, transport) = fetcher(HTTPResult(status: 200, body: image))
        for text in allowed {
            #expect(try await fetcher.fetch(try #require(URL(string: text))) == image, "\(text)")
        }
        for text in refused {
            let target = try #require(URL(string: text), "\(text)")
            await #expect(throws: GooglePhotoError.self, "\(text)") { try await fetcher.fetch(target) }
        }
        #expect(transport.requests.count == allowed.count)
    }

    @Test("A refused address says why")
    func refusalReason() async throws {
        let (fetcher, _) = fetcher(HTTPResult(status: 200, body: image))
        await #expect(throws: GooglePhotoError.notAllowed("the address is not https")) { try await fetcher.fetch(URL(string: "http://lh3.googleusercontent.com/x")!) }
        await #expect(throws: GooglePhotoError.notAllowed("the address is not on googleusercontent.com")) { try await fetcher.fetch(URL(string: "https://example.com/x")!) }
    }

    @Test("A download over 10 MB is refused, one at the limit is not")
    func sizeLimit() async throws {
        // Valid JPEG bytes padded after the end marker: decodes, but is as big as we like.
        let atLimit = image + Data(repeating: 0, count: 10_000_000 - image.count)
        #expect(atLimit.count == 10_000_000)
        let (fine, _) = fetcher(HTTPResult(status: 200, body: atLimit))
        #expect(try await fine.fetch(url).count == 10_000_000)

        let (huge, _) = fetcher(HTTPResult(status: 200, body: atLimit + Data([0])))
        await #expect(throws: GooglePhotoError.tooLarge) { try await huge.fetch(url) }
    }

    @Test("Bytes that do not decode as an image are refused")
    func mustDecode() async throws {
        for body in [Data("<html>sign in</html>".utf8), Data(), Data(image.prefix(20))] {
            let (fetcher, _) = fetcher(HTTPResult(status: 200, body: body))
            await #expect(throws: GooglePhotoError.notAnImage) { try await fetcher.fetch(url) }
        }
    }

    @Test("A failed answer is reported with its status, and a transport error is passed on as it is")
    func failures() async throws {
        for status in [403, 404, 500] {
            let (fetcher, _) = fetcher(HTTPResult(status: status, body: image))
            await #expect(throws: GooglePhotoError.http(status)) { try await fetcher.fetch(url) }
        }
        let transport = FakeHTTPTransport()
        await transport.route("GET", "googleusercontent", [.networkDown])
        await #expect(throws: URLError.self) { try await URLSessionGooglePhotoFetcher(transport: transport).fetch(url) }
    }

    @Test("PNG and HEIC photos are accepted as they are")
    func formats() async throws {
        let scene = PhotoTestImages.scene(seed: 8, width: 200, height: 200)
        for data in [PhotoTestImages.encode(scene, as: .png), PhotoTestImages.encode(scene, as: .heic)] {
            let body = try #require(data)
            let (fetcher, _) = fetcher(HTTPResult(status: 200, body: body))
            #expect(try await fetcher.fetch(url) == body)
        }
    }

    // MARK: fake

    @Test("The fake serves the photos the fake Google holds, at any size, and applies the same address rules")
    func fakeFetcher() async throws {
        let google = FakeGoogleClient(people: [SyncFixtures.person("Ann", "Lee")])
        let photo = PhotoTestImages.jpeg(PhotoTestImages.solid(.green))
        let person = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: photo)
        let ref = try #require(GooglePersonMapper.photos(of: person).contact)
        let fake = FakeGooglePhotoFetcher(client: google)

        #expect(try await fake.fetch(try #require(ref.sizedURL(128))) == photo)
        #expect(try await fake.fetch(try #require(ref.sizedURL(1024))) == photo)
        let asked = await fake.requested.map(\.absoluteString)
        #expect(asked.count == 2 && asked[0].hasSuffix("=s128") && asked[1].hasSuffix("=s1024"))

        await #expect(throws: GooglePhotoError.http(404)) { try await fake.fetch(URL(string: "https://lh3.googleusercontent.com/fake/unknown/9=s128")!) }
        await #expect(throws: GooglePhotoError.self) { try await fake.fetch(URL(string: "http://lh3.googleusercontent.com/x")!) }
        await fake.failNext(with: .http(503))
        await #expect(throws: GooglePhotoError.http(503)) { try await fake.fetch(try #require(ref.sizedURL(128))) }
        #expect(try await fake.fetch(try #require(ref.sizedURL(128))) == photo)
        #expect(await fake.requested.count == 6)
    }
}
