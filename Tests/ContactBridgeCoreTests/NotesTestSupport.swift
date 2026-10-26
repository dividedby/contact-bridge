import Foundation
@testable import ContactBridgeCore

enum ScriptValue {
    static func string(_ text: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: text) }
    /// AppleScript's `missing value`, as NSAppleScript really returns it: a type descriptor holding 'msng', not typeNull
    /// (verified against `return missing value`; `realMissingValueShape` in the provider tests keeps this honest).
    static func missing() -> NSAppleEventDescriptor { NSAppleEventDescriptor(typeCode: 0x6D73_6E67) }

    static func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    /// What `get {id, note} of every person` returns: two parallel lists.
    static func bulk(ids: [String], notes: [String?]) -> NSAppleEventDescriptor {
        list([
            list(ids.map(string)),
            list(notes.map { $0.map(string) ?? missing() }),
        ])
    }

    static func strings(_ descriptor: NSAppleEventDescriptor) -> [String?] {
        (0..<descriptor.numberOfItems).map { descriptor.atIndex($0 + 1)?.stringValue }
    }
}
