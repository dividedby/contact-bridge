import Testing
@testable import ContactBridgeCore

struct ContainerResolverTests {
    private func container(_ id: String, _ name: String, _ kind: ContactContainer.Kind = .cardDAV, isDefault: Bool = false) -> ContactContainer {
        ContactContainer(id: id, name: name, kind: kind, isDefault: isDefault)
    }

    private let icloud = ContactContainer(id: "ic", name: "iCloud", kind: .cardDAV, isDefault: true)
    private let fastmail = ContactContainer(id: "fm", name: "Fastmail", kind: .cardDAV, isDefault: false)
    private let personal = ContactContainer(id: "pe", name: "Personal", kind: .cardDAV, isDefault: false)

    @Test("Without a saved choice it follows ContainerSelection")
    func automatic() {
        #expect(ContainerResolver.resolve(containers: [icloud, fastmail], savedID: nil) == .selected(icloud, viaSavedChoice: false))
        #expect(ContainerResolver.resolve(containers: [fastmail, personal], savedID: nil) == .needsUserChoice([fastmail, personal]))
        #expect(ContainerResolver.resolve(containers: [container("l", "On My Mac", .local)], savedID: nil) == .none)
        #expect(ContainerResolver.resolve(containers: [], savedID: nil) == .none)
    }

    @Test("A saved choice that still exists wins, even over an automatic iCloud pick")
    func savedWins() {
        #expect(ContainerResolver.resolve(containers: [icloud, fastmail], savedID: "fm") == .selected(fastmail, viaSavedChoice: true))
        #expect(ContainerResolver.resolve(containers: [fastmail, personal], savedID: "pe") == .selected(personal, viaSavedChoice: true))
    }

    @Test("A saved choice that vanished, or is not a CardDAV container, is never silently replaced: the user must pick")
    func staleSaved() {
        #expect(ContainerResolver.resolve(containers: [icloud], savedID: "gone") == .savedChoiceUnavailable(options: [icloud]))
        let local = container("l", "On My Mac", .local)
        #expect(ContainerResolver.resolve(containers: [icloud, local], savedID: "l") == .savedChoiceUnavailable(options: [icloud]))
        #expect(ContainerResolver.resolve(containers: [fastmail, personal], savedID: "gone") == .savedChoiceUnavailable(options: [fastmail, personal]))
        #expect(ContainerResolver.resolve(containers: [], savedID: "gone") == .none)
    }

    @Test("The first-choice list never offers a Gmail container when something else exists")
    func gmailNotOffered() {
        let gmail = container("gm", "Gmail")
        #expect(ContainerResolver.resolve(containers: [gmail, fastmail, personal], savedID: nil) == .needsUserChoice([fastmail, personal]))
    }
}
