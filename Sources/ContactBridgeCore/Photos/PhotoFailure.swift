import Foundation

/// Which photo errors are worth trying again. A refused address, a picture that cannot be decoded or is too large, or a 4xx
/// answer from Google's servers will fail the same way next time; a dropped connection, a 5xx or a timeout may not.
/// (Rate limits and sign-in problems are neither: they stop the whole run, see `SyncExecutor.haltReason`.)
enum PhotoErrors {
    static func isPermanent(_ error: any Error) -> Bool {
        switch error {
        case is PhotoEncodingError: true
        case let error as GooglePhotoError:
            switch error {
            case .notAllowed, .notAnImage, .tooLarge: true
            case .http(let status): isClientError(status)
            }
        case let error as GoogleAPIError:
            if case .other(let status, _) = error { isClientError(status) } else { false }
        default: false
        }
    }

    /// 408, 409 (Google's ABORTED: a concurrent write) and 429 are answers to try again.
    private static func isClientError(_ status: Int) -> Bool { (400..<500).contains(status) && ![408, 409, 429].contains(status) }
}

/// A photo of a pair that could not be read, found by `PhotoReconciler`. The planner stores it as a failure on the pair's
/// photo baseline so the photo is not read again until it changes.
public struct PhotoReadFailure: Sendable, Hashable {
    public var resourceName: String
    public var stamp: String
    public var message: String
}
