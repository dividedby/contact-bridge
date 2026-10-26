import Foundation
@testable import ContactBridgeCore

extension HTTPResult {
    static func json(_ status: Int = 200, _ body: String = "{}", headers: [String: String] = [:]) -> HTTPResult {
        HTTPResult(status: status, headers: headers, body: Data(body.utf8))
    }

    /// Makes the fake transport throw `URLError(.notConnectedToInternet)` instead of answering.
    static let networkDown = HTTPResult(status: 0)

    static func fixture(_ status: Int, _ name: String, headers: [String: String] = [:]) throws -> HTTPResult {
        HTTPResult(status: status, headers: headers, body: try GoogleFixtures.data(name))
    }
}

/// Scripted transport: each route answers matching requests with its responses in order, repeating the last one.
actor FakeHTTPTransport: HTTPTransport {
    struct Recorded: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data

        var bodyString: String { String(decoding: body, as: UTF8.self) }
        var bodyJSON: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var query: [String: String] {
            Dictionary(
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
        }
        /// Form-encoded body as name/value pairs.
        var form: [String: String] {
            var components = URLComponents()
            components.percentEncodedQuery = bodyString
            return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
    }

    private struct Route {
        var method: String
        var urlContains: String
        var bodyContains: String?
        var responses: [HTTPResult]
        var delay: Duration?
        var hold: AsyncStream<Void>?
        var used = 0
    }

    private var routes: [Route] = []
    private(set) var requests: [Recorded] = []

    /// - Parameters:
    ///   - delay: answers this long after the request arrived.
    ///   - hold: answers only once this stream yields (or finishes). Unlike `delay` it does not depend on how fast the
    ///     rest of the test runs, so a test can order events around the answer exactly.
    func route(
        _ method: String, _ urlContains: String, _ responses: [HTTPResult], bodyContains: String? = nil, delay: Duration? = nil,
        hold: AsyncStream<Void>? = nil
    ) {
        routes.append(Route(method: method, urlContains: urlContains, bodyContains: bodyContains, responses: responses, delay: delay, hold: hold))
    }

    func requests(_ method: String? = nil, containing fragment: String) -> [Recorded] {
        requests.filter { (method == nil || $0.method == method) && $0.url.absoluteString.contains(fragment) }
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let method = request.httpMethod ?? "GET"
        let url = try Self.require(request.url)
        requests.append(Recorded(
            method: method, url: url, headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Data()
        ))
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard let index = routes.firstIndex(where: {
            $0.method == method && url.absoluteString.contains($0.urlContains) && ($0.bodyContains.map(body.contains) ?? true)
        }) else {
            throw URLError(.resourceUnavailable)
        }
        routes[index].used += 1
        let route = routes[index]
        if let hold = route.hold {
            for await _ in hold { break }
            try Task.checkCancellation()
        } else if let delay = route.delay {
            try await Task.sleep(for: delay)
        }
        let response = route.responses[min(route.used, route.responses.count) - 1]
        if response.status == 0 { throw URLError(.notConnectedToInternet) }
        return response
    }

    private static func require(_ url: URL?) throws -> URL {
        guard let url else { throw URLError(.badURL) }
        return url
    }
}
