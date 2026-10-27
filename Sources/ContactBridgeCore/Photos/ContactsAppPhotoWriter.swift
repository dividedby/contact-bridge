import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sets or removes an iCloud contact's photo through the Contacts app, for contacts whose photo `CNContactStore` cannot save
/// (Cocoa error 134092, `ContactStoreError.photoNotSaved`). On such a contact the Contacts app's own write still works and
/// the photo reads back through the Contacts framework, while the framework's save keeps failing (seen on macOS 27).
public protocol ContactsAppPhotoWriting: Sendable {
    /// Sets the photo to these image bytes, or removes it when `data` is nil.
    func setPhoto(_ data: Data?, forID id: String) async throws
}

/// Uses the Automation permission for Contacts that notes already need.
public struct ContactsAppPhotoWriter: ContactsAppPhotoWriting {
    private let runner: any AppleScriptRunning
    private let retryDelay: Duration

    public init(runner: any AppleScriptRunning = NSAppleScriptRunner(), retryDelay: Duration = .seconds(1)) {
        self.runner = runner
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
        _ = try await ContactsAppScript.retryingLaunch(after: retryDelay) {
            try await ContactsAppScript.call(handler: handler, in: Self.script, arguments: arguments, runner: runner)
        }
    }

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
