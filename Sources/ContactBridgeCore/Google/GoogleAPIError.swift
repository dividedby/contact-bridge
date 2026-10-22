import Foundation

public enum GoogleAPIError: Error, Sendable, Hashable {
    /// HTTP 410 / `EXPIRED_SYNC_TOKEN`: drop the token and do a full sync.
    case syncTokenExpired
    /// HTTP 400 `FAILED_PRECONDITION`: the person changed since its etag was read; refetch and retry.
    case etagMismatch
    /// HTTP 429 (or `RATE_LIMIT_EXCEEDED`); `retryAfter` is the server's hint in seconds, when given.
    case rateLimited(retryAfter: TimeInterval?)
    case notFound
    case unauthorized
    case other(status: Int, message: String)

    /// Classifies an error response. `retryAfter` is the parsed `Retry-After` header, if any.
    ///
    /// A precondition failure is an etag mismatch only when its message says so (Google also uses
    /// `FAILED_PRECONDITION` for things like a full contact group); anything unrecognised stays `.other`.
    public static func parse(status: Int, body: Data, retryAfter: TimeInterval? = nil) -> GoogleAPIError {
        let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: body)
        let reasons = (envelope?.error.details?.compactMap(\.reason) ?? []) + (envelope?.error.errors?.compactMap(\.reason) ?? [])
        let message = envelope?.error.message ?? String(decoding: body, as: UTF8.self)
        let lowered = message.lowercased()

        // Expired sync tokens arrive as 410 or as 400 FAILED_PRECONDITION, with or without ErrorInfo.
        if status == 410 || reasons.contains("EXPIRED_SYNC_TOKEN") || lowered.contains("sync token") { return .syncTokenExpired }
        let rateLimitReasons: Set<String> = ["RATE_LIMIT_EXCEEDED", "rateLimitExceeded", "userRateLimitExceeded"]
        if status == 429 || reasons.contains(where: rateLimitReasons.contains) { return .rateLimited(retryAfter: retryAfter) }
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 400 where envelope?.error.status == "FAILED_PRECONDITION" && lowered.contains("etag"): return .etagMismatch
        default: return .other(status: status, message: message)
        }
    }

    /// Delay-seconds form of `Retry-After`. HTTP-date values are not parsed.
    public static func retryAfter(fromHeader value: String?) -> TimeInterval? {
        guard let value else { return nil }
        return TimeInterval(value.trimmingCharacters(in: .whitespaces))
    }
}

private struct GoogleErrorEnvelope: Decodable {
    struct Detail: Decodable {
        var reason: String?
    }

    /// Legacy (Google API v1 style) error entries.
    struct LegacyError: Decodable {
        var reason: String?
    }

    struct Body: Decodable {
        var code: Int?
        var message: String?
        var status: String?
        var details: [Detail]?
        var errors: [LegacyError]?
    }

    var error: Body
}
