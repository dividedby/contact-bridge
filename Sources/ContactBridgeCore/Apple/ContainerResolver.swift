import Foundation

public enum ContainerResolution: Sendable, Equatable {
    case selected(ContactContainer, viaSavedChoice: Bool)
    /// Several plausible containers and no safe default; the user picks and the app saves the id.
    case needsUserChoice([ContactContainer])
    /// The user chose a container earlier and it is gone (or is no longer CardDAV). Nothing is chosen for them: writes stay
    /// blocked until they pick again from `options`.
    case savedChoiceUnavailable(options: [ContactContainer])
    case none
}

/// `ContainerSelection` plus the user's remembered choice. A saved id wins while that container still exists and is
/// CardDAV. If it does not, the automatic policy is NOT applied in its place: the user is asked again, because silently
/// switching accounts could send a merge or import to the wrong one. Without a saved id the automatic policy applies.
public enum ContainerResolver {
    public static func resolve(containers: [ContactContainer], savedID: String?) -> ContainerResolution {
        if let savedID, let saved = containers.first(where: { $0.id == savedID && $0.kind == .cardDAV }) {
            return .selected(saved, viaSavedChoice: true)
        }
        let automatic = ContainerSelection.choose(from: containers)
        if savedID != nil {
            switch automatic {
            case .selected(let container): return .savedChoiceUnavailable(options: [container])
            case .needsUserChoice(let options): return .savedChoiceUnavailable(options: options)
            case .none: return .none
            }
        }
        switch automatic {
        case .selected(let container): return .selected(container, viaSavedChoice: false)
        case .needsUserChoice(let options): return .needsUserChoice(options)
        case .none: return .none
        }
    }
}

/// Lists contact containers so the UI can show or ask for one. `CNContactStoreAdapter` conforms.
public protocol ContactContainerListing: Sendable {
    func containers() async throws -> [ContactContainer]
}

extension CNContactStoreAdapter: ContactContainerListing {}
