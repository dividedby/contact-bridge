import Testing
@testable import ContactBridgeCore

struct ContainerSelectionTests {
    private func container(
        _ id: String, _ name: String, _ kind: ContactContainer.Kind = .cardDAV, isDefault: Bool = false
    ) -> ContactContainer {
        ContactContainer(id: id, name: name, kind: kind, isDefault: isDefault)
    }

    @Test("A single iCloud CardDAV container is selected")
    func single() {
        let icloud = container("1", "iCloud")
        #expect(ContainerSelection.choose(from: [icloud, container("2", "On My Mac", .local)]) == .selected(icloud))
    }

    @Test("Exchange, local and unassigned containers are never candidates")
    func nonCardDAV() {
        #expect(ContainerSelection.choose(from: [container("1", "Work", .exchange), container("2", "Mac", .local)]) == .none)
        #expect(ContainerSelection.choose(from: []) == .none)
    }

    @Test("A lone Gmail container is never selected silently")
    func gmailAlone() {
        let gmail = container("1", "Gmail", isDefault: true)
        #expect(ContainerSelection.choose(from: [gmail]) == .needsUserChoice([gmail]))
    }

    @Test("A container that is not named iCloud is never auto-selected, even alone", arguments: ["Personal", "Fastmail", "Work"])
    func loneNonICloud(name: String) {
        let only = container("1", name, isDefault: true)
        #expect(ContainerSelection.choose(from: [only]) == .needsUserChoice([only]))
    }

    @Test("iCloud wins over a renamed Gmail container that is the default")
    func renamedGmailDefault() {
        let icloud = container("1", "iCloud")
        let renamed = container("2", "Personal", isDefault: true)
        #expect(ContainerSelection.choose(from: [renamed, icloud]) == .selected(icloud))
    }

    @Test("The iCloud name match ignores case and surrounding spaces, and is exact")
    func exactName() {
        let icloud = container("1", " ICLOUD ")
        #expect(ContainerSelection.choose(from: [icloud]) == .selected(icloud))
        let lookalike = container("2", "iCloud Archive")
        #expect(ContainerSelection.choose(from: [lookalike]) == .needsUserChoice([lookalike]))
    }

    @Test("Gmail is skipped in favour of iCloud, even when Gmail is the default")
    func gmailSkipped() {
        let icloud = container("1", "iCloud")
        let gmail = container("2", "Gmail", isDefault: true)
        #expect(ContainerSelection.choose(from: [gmail, icloud]) == .selected(icloud))
    }

    @Test("With several iCloud-named containers the default wins, else the user chooses")
    func severalICloud() {
        let first = container("1", "iCloud")
        let second = container("2", "iCloud", isDefault: true)
        #expect(ContainerSelection.choose(from: [first, second]) == .selected(second))
        #expect(ContainerSelection.choose(from: [first, container("3", "iCloud")]) ==
            .needsUserChoice([first, container("3", "iCloud")]))
    }

    @Test("Without iCloud the user chooses among CardDAV containers, Google last-resort only")
    func noICloud() {
        let fastmail = container("2", "Fastmail")
        let work = container("3", "Work CardDAV", isDefault: true)
        let gmail = container("4", "Gmail")
        let local = container("5", "On My Mac", .local)
        #expect(ContainerSelection.choose(from: [gmail, fastmail, local, work]) == .needsUserChoice([fastmail, work]))
    }

    @Test("Google detection ignores case")
    func googleCase() {
        #expect(ContactContainer(id: "1", name: "My GMAIL account", kind: .cardDAV, isDefault: false).looksLikeGoogle)
        #expect(!ContactContainer(id: "1", name: "iCloud", kind: .cardDAV, isDefault: false).looksLikeGoogle)
    }
}
