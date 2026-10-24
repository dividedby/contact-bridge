import Foundation
import Synchronization

public enum SyncLockError: Error, Sendable, Equatable {
    /// Another Contact Bridge process holds the sync lock.
    case heldByAnotherInstance
    /// The lock file could not be opened or locked.
    case unavailable(String)
}

extension SyncLockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .heldByAnotherInstance:
            "Another copy of Contact Bridge is already running and syncing, so syncing is off in this one. Quit the other copy to sync from here."
        case .unavailable(let reason):
            "Contact Bridge could not make sure it is the only copy syncing, so syncing is off: \(reason)"
        }
    }
}

/// Something that keeps sync exclusive to this process for as long as it is alive.
public protocol SyncLockHolding: AnyObject, Sendable {
    /// Lets go of the lock now instead of when the object goes away.
    func release()
}

/// The second-instance guard: an exclusive, non-blocking `flock` on `sync.lock` next to `links.json`. The operating system
/// drops the lock when the process ends, however it ends, so a crash never leaves a stale lock behind.
public final class SyncProcessLock: SyncLockHolding, Sendable {
    public static var defaultURL: URL {
        LinkStore.defaultURL.deletingLastPathComponent().appendingPathComponent("sync.lock")
    }

    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    /// Takes the lock or throws `heldByAnotherInstance`. Two calls on the same file conflict even inside one process, because
    /// each opens its own descriptor.
    public static func acquire(at url: URL = SyncProcessLock.defaultURL) throws -> SyncProcessLock {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw SyncLockError.unavailable(error.localizedDescription)
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SyncLockError.unavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? SyncLockError.heldByAnotherInstance : SyncLockError.unavailable(String(cString: strerror(code)))
        }
        return SyncProcessLock(descriptor: fd)
    }

    public func release() {
        descriptor.withLock { fd in
            guard let held = fd else { return }
            flock(held, LOCK_UN)
            close(held)
            fd = nil
        }
    }

    deinit {
        release()
    }
}
