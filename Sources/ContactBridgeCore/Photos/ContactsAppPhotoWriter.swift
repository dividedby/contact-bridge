import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Sets or removes an iCloud contact's photo through the Contacts app, for contacts whose photo `CNContactStore` cannot save
/// (Cocoa error 134092, `ContactStoreError.photoNotSaved`). On such a contact the Contacts app's own write still works and
/// the photo reads back through the Contacts framework, while the framework's save keeps failing (seen on macOS 27).
public protocol ContactsAppPhotoWriting: Sendable {
    /// Sets the photo to these image bytes, or removes it when `data` is nil. Throws `ContactsAppUnavailable` when the
    /// Contacts app could not be reached, which is worth trying again.
    func setPhoto(_ data: Data?, forID id: String) async throws
    /// Called once the run's photo writes are done.
    func finish() async
}

extension ContactsAppPhotoWriting {
    public func finish() async {}
}

/// Opens and quits the Contacts app (`NSWorkspace` in the app). A script cannot launch Contacts from inside the sandbox: it
/// fails with -600 when Contacts is not running.
public protocol ContactsAppLaunching: Sendable {
    func isRunning() async -> Bool
    /// Opens Contacts in the background, hidden and without taking the focus.
    func openHidden() async throws
    /// Quits Contacts if it is still hidden: nobody started using it since `openHidden`.
    func quitIfStillHidden() async
}

/// The Contacts app could not be reached to write a photo; the write is tried again next run.
public struct ContactsAppUnavailable: Error, Sendable, Equatable {
    public var reason: String
}

/// Uses the Automation permission for Contacts that notes already need. Opens Contacts hidden when it is not running, and
/// quits it again in `finish` if it opened it.
public struct ContactsAppPhotoWriter: ContactsAppPhotoWriting {
    private let runner: any AppleScriptRunning
    private let launcher: (any ContactsAppLaunching)?
    private let retryDelay: Duration
    /// Whether this writer opened Contacts and has not quit it yet.
    private let openedContacts = Flag()

    private final class Flag: Sendable {
        let value = Mutex(false)
    }

    public init(
        runner: any AppleScriptRunning = NSAppleScriptRunner(), launcher: (any ContactsAppLaunching)? = nil, retryDelay: Duration = .seconds(1)
    ) {
        self.runner = runner
        self.launcher = launcher
        self.retryDelay = retryDelay
    }

    // MARK: scripts (constant text: the id and the picture arrive as handler arguments)

    static let setHandler = "setPhoto"
    static let removeHandler = "removePhoto"
    /// `pid` is the exact id, `pidUUID` the part before ":" (as for notes). `pic` is a TIFF picture. Contacts only persists
    /// after `save`.
    static let script = """
        on findPerson(pid, pidUUID)
            if pid is "" or pidUUID is "" then error "No contact id given." number -1728
            tell application id "com.apple.AddressBook"
                set matches to every person whose id is pid
                if (count of matches) is 0 then set matches to every person whose id begins with pidUUID
                if (count of matches) is 0 then error "No contact with that id." number -1728
                return item 1 of matches
            end tell
        end findPerson

        on setPhoto(pid, pidUUID, pic)
            set p to findPerson(pid, pidUUID)
            tell application id "com.apple.AddressBook"
                set image of p to pic
                save
            end tell
            return true
        end setPhoto

        on removePhoto(pid, pidUUID)
            set p to findPerson(pid, pidUUID)
            tell application id "com.apple.AddressBook"
                delete image of p
                save
            end tell
            return true
        end removePhoto
        """

    public func setPhoto(_ data: Data?, forID id: String) async throws {
        // An empty UUID part would make `begins with ""` match every contact.
        guard !ContactsAppIDs.uuidPart(of: id).isEmpty else { throw NotesAccessError.contactNotFound(id) }
        var arguments = [id, ContactsAppIDs.uuidPart(of: id)].map { NSAppleEventDescriptor(string: $0) }
        if let data {
            guard let picture = NSAppleEventDescriptor(descriptorType: Self.tiffType, data: try Self.tiff(data)) else {
                throw PhotoEncodingError.undecodable
            }
            arguments.append(picture)
        }
        let handler = data == nil ? Self.removeHandler : Self.setHandler
        try await openContactsIfNeeded()
        do {
            _ = try await ContactsAppScript.retryingLaunch(after: retryDelay) {
                try await ContactsAppScript.call(handler: handler, in: Self.script, arguments: arguments, runner: runner)
            }
        } catch let error as AppleScriptError where Self.unreachable.keys.contains(error.number) {
            throw ContactsAppUnavailable(reason: Self.unreachable[error.number] ?? error.message)
        }
    }

    public func finish() async {
        guard openedContacts.value.withLock({ opened in defer { opened = false }; return opened }) else { return }
        await launcher?.quitIfStillHidden()
    }

    private func openContactsIfNeeded() async throws {
        guard let launcher, await !launcher.isRunning() else { return }
        do {
            try await launcher.openHidden()
        } catch {
            throw ContactsAppUnavailable(reason: "it is not running and could not be opened (\(error.localizedDescription))")
        }
        openedContacts.value.withLock { $0 = true }
        try await waitUntilAnswering()
    }

    /// Times `retryDelay` that a just-opened Contacts is given to answer.
    static let launchPolls = 60

    /// Contacts answers scripts only some time after it opens (16 to 33 seconds seen); until then they fail with -600.
    private func waitUntilAnswering() async throws {
        for _ in 0..<Self.launchPolls {
            do {
                _ = try await runner.run(source: ContactsAppScript.wakeScript)
                return
            } catch let error as AppleScriptError where error.number == AppleScriptError.appNotRunning {
                try await Task.sleep(for: retryDelay)
            } catch let error as AppleScriptError where Self.unreachable.keys.contains(error.number) {
                throw ContactsAppUnavailable(reason: Self.unreachable[error.number] ?? error.message)
            }
        }
        throw ContactsAppUnavailable(reason: "it was opened but did not answer")
    }

    /// AppleScript errors that mean Contacts was not reached, rather than that it refused the photo.
    static let unreachable: [Int: String] = [
        AppleScriptError.appNotRunning: "it is not running",
        AppleScriptError.notAuthorized: "Contact Bridge is not allowed to control it (System Settings > Privacy & Security > Automation)",
        -1712: "it did not answer in time",
    ]

    /// AppleScript's `TIFF picture` ('TIFF'), the class of a person's `image`.
    static let tiffType: DescType = 0x5449_4646

    static func tiff(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PhotoEncodingError.undecodable }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)
        else { throw PhotoEncodingError.undecodable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEncodingError.undecodable }
        return out as Data
    }
}
