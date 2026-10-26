import Foundation
import Synchronization

public enum SyncStateStoreError: Error, Sendable, Equatable {
    /// The file was written by a different version of the format; it is left alone.
    case unsupportedVersion(Int)
    /// The file exists but cannot be read or understood; it is left alone.
    case unreadable(String)
}

extension SyncStateStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "sync-state.json was written by a newer version of Contact Bridge (format \(version)) and was left as it was. Update the app."
        case .unreadable(let reason):
            "sync-state.json could not be read and was left as it was: \(reason)"
        }
    }
}

public protocol SyncStateStoring: Sendable {
    /// A fresh `SyncState` when nothing is stored yet.
    func load() throws -> SyncState
    /// Replaces the stored state. Throws without changing anything if the stored data cannot be read.
    func save(_ state: SyncState) throws
    /// One read-modify-write; returns the state that was stored. Throws without changing anything if the stored data
    /// cannot be read or `change` throws.
    @discardableResult
    func update(_ change: (inout SyncState) throws -> Void) throws -> SyncState
}

/// `sync-state.json` next to `links.json`: the baselines, tokens and sync switches (`SyncState`), rewritten atomically
/// (temp file in the same folder, then rename) on every change.
public final class SyncStateStore: SyncStateStoring, Sendable {
    public static var defaultURL: URL {
        LinkStore.defaultURL.deletingLastPathComponent().appendingPathComponent("sync-state.json")
    }

    private let url: URL
    /// Serializes read-modify-write within this process.
    private let lock = Mutex(())

    public init(url: URL = SyncStateStore.defaultURL) {
        self.url = url
    }

    public func load() throws -> SyncState { try lock.withLock { _ in try read() } }

    public func save(_ state: SyncState) throws {
        try lock.withLock { _ in
            _ = try read()
            try write(state)
        }
    }

    @discardableResult
    public func update(_ change: (inout SyncState) throws -> Void) throws -> SyncState {
        try lock.withLock { _ in
            var state = try read()
            let before = state
            try change(&state)
            if state != before { try write(state) }
            return state
        }
    }

    private struct Header: Decodable {
        var version: Int
    }

    private func read() throws -> SyncState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return SyncState()
        } catch {
            throw SyncStateStoreError.unreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == SyncState.currentVersion else { throw SyncStateStoreError.unsupportedVersion(header.version) }
            return try decoder.decode(SyncState.self, from: data)
        } catch let error as SyncStateStoreError {
            throw error
        } catch {
            throw SyncStateStoreError.unreadable(error.localizedDescription)
        }
    }

    private func write(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

/// For previews, the demo mode and tests: same semantics, nothing on disk.
public final class InMemorySyncStateStore: SyncStateStoring, Sendable {
    private let state: Mutex<SyncState>

    public init(_ state: SyncState = SyncState()) {
        self.state = Mutex(state)
    }

    public func load() throws -> SyncState { state.withLock { $0 } }
    public func save(_ new: SyncState) throws { state.withLock { $0 = new } }

    @discardableResult
    public func update(_ change: (inout SyncState) throws -> Void) throws -> SyncState {
        try state.withLock { state in
            var copy = state
            try change(&copy)
            state = copy
            return copy
        }
    }
}
