import Foundation

public struct ContactContainer: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case local
        case exchange
        case cardDAV
        case unassigned
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// This is the store's default container.
    public var isDefault: Bool

    public init(id: String, name: String, kind: Kind, isDefault: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
    }

    /// Exactly "iCloud", ignoring case and surrounding whitespace.
    public var isNamedICloud: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "icloud"
    }

    /// Gmail also appears as a CardDAV container. Google contacts are handled by the Google adapter, so this layer
    /// must never write to one by default.
    public var looksLikeGoogle: Bool {
        let lowered = name.lowercased()
        return lowered.contains("gmail") || lowered.contains("google")
    }
}

public enum ContainerChoice: Sendable, Equatable {
    case selected(ContactContainer)
    /// The user has to choose; the list keeps the given order and contains Google containers only if nothing else exists.
    case needsUserChoice([ContactContainer])
    case none
}

/// Pure container-picking policy, separate from CNContactStore so it can be tested.
///
/// Only a CardDAV container named exactly "iCloud" is ever chosen automatically. Anything else (a lone "Personal"
/// container, Fastmail, a Gmail container renamed or not, even the system default) needs the user's explicit choice,
/// which the app then persists and passes back as the adapter's `containerID`.
public enum ContainerSelection {
    public static func choose(from containers: [ContactContainer]) -> ContainerChoice {
        let cardDAV = containers.filter { $0.kind == .cardDAV }
        guard !cardDAV.isEmpty else { return .none }

        let icloud = cardDAV.filter(\.isNamedICloud)
        if icloud.count == 1 { return .selected(icloud[0]) }
        if icloud.count > 1 {
            if let preferred = icloud.first(where: \.isDefault) { return .selected(preferred) }
            return .needsUserChoice(icloud)
        }

        let nonGoogle = cardDAV.filter { !$0.looksLikeGoogle }
        return .needsUserChoice(nonGoogle.isEmpty ? cardDAV : nonGoogle)
    }
}
