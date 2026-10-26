import Foundation

public enum GooglePhotoError: Error, Sendable, Hashable {
    /// The URL is not one this app will download from: not https, or not a googleusercontent.com host.
    case notAllowed(String)
    /// Google's photo server answered with this status.
    case http(Int)
    /// The photo is bigger than `GooglePhotoFetching.maxBytes`.
    case tooLarge
    /// The bytes are not a picture.
    case notAnImage
}

/// Downloads a photo from the URL Google gave for it. The URL is public and carries no credentials: the request has no
/// authorization header, so the access token never leaves for a host Google's answer chose.
public protocol GooglePhotoFetching: Sendable {
    /// The image bytes. Throws `GooglePhotoError` for a URL that is not allowed, a failed or oversized answer, or bytes that
    /// are not an image; transport errors are thrown as they are.
    func fetch(_ url: URL) async throws -> Data
}

extension GooglePhotoFetching {
    /// Largest download accepted.
    public static var maxBytes: Int { 10_000_000 }
    public static var timeout: TimeInterval { 20 }
    static var hostSuffix: String { ".googleusercontent.com" }

    /// Throws `notAllowed` unless `url` is https on a host under googleusercontent.com (default port, no credentials).
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else { throw GooglePhotoError.notAllowed("the address is not https") }
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw GooglePhotoError.notAllowed("the address has credentials or a port")
        }
        guard let host = url.host?.lowercased(), host.hasSuffix(hostSuffix), host.count > hostSuffix.count else {
            throw GooglePhotoError.notAllowed("the address is not on googleusercontent.com")
        }
    }
}

/// The real downloader over an `HTTPTransport`; the default transport is a private ephemeral session (no cookies, no cache,
/// 20 s, 10 MB, redirects only to allowed hosts).
public struct URLSessionGooglePhotoFetcher: GooglePhotoFetching {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = GooglePhotoDownloadTransport()) {
        self.transport = transport
    }

    public func fetch(_ url: URL) async throws -> Data {
        try Self.validate(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let result = try await transport.send(request)
        guard result.isSuccess else { throw GooglePhotoError.http(result.status) }
        guard result.body.count <= Self.maxBytes else { throw GooglePhotoError.tooLarge }
        guard PhotoImage.isDecodable(result.body) else { throw GooglePhotoError.notAnImage }
        return result.body
    }
}

/// `HTTPTransport` for photo downloads: its own ephemeral session, a hard 20 s limit, and a body limit enforced while
/// streaming (so an oversized answer is cut off, not downloaded). A redirect to anything the policy does not allow fails.
/// Not exercised by automated tests (it needs the network); the policy it applies is tested through the fetcher.
public struct GooglePhotoDownloadTransport: HTTPTransport {
    private let session: URLSession
    private let maxBytes: Int

    public init(maxBytes: Int = URLSessionGooglePhotoFetcher.maxBytes) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = URLSessionGooglePhotoFetcher.timeout
        configuration.timeoutIntervalForResource = URLSessionGooglePhotoFetcher.timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        self.maxBytes = maxBytes
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectPolicy())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(maxBytes) { throw GooglePhotoError.tooLarge }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBytes { throw GooglePhotoError.tooLarge }
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
        return HTTPResult(status: http.statusCode, headers: headers, body: body)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, (try? URLSessionGooglePhotoFetcher.validate(url)) != nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}

/// Serves the photos a `FakeGoogleClient` holds, validating URLs like the real downloader. Counts what was asked for, and
/// can be made to fail.
public actor FakeGooglePhotoFetcher: GooglePhotoFetching {
    private let client: FakeGoogleClient
    private var failures: [GooglePhotoError] = []
    /// Every URL requested, in order, including ones that failed.
    public private(set) var requested: [URL] = []

    public init(client: FakeGoogleClient) {
        self.client = client
    }

    /// The next `fetch` throws this.
    public func failNext(with error: GooglePhotoError) { failures.append(error) }

    public func fetch(_ url: URL) async throws -> Data {
        requested.append(url)
        try Self.validate(url)
        if !failures.isEmpty { throw failures.removeFirst() }
        guard let bytes = await client.photoBytes(forURL: url) else { throw GooglePhotoError.http(404) }
        return bytes
    }
}
