import Foundation
import Testing
@testable import ContactBridgeCore

struct MergeDraftTests {
    private func person(
        _ id: String, _ given: String, _ family: String, phones: [(String, String)] = [], emails: [String] = [],
        org: String = "", job: String = ""
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family, organization: org, jobTitle: job,
            phones: phones.map { Labeled(label: $0.0, value: $0.1) }, emails: emails.map { Labeled(label: "home", value: $0) }
        )
    }

    private func edge(_ a: String, _ b: String, _ confidence: Double, flags: [MatchFlag] = [], reasons: [String] = ["r"]) -> ClusterEdge {
        ClusterEdge(firstID: a, secondID: b, match: PairMatch(confidence: confidence, reasons: reasons, flags: flags))
    }

    /// a-b strong, b-c strong, a-c unscored; d hangs off c by a weak related edge to an outsider "z".
    private func threeMemberCluster() -> DuplicateCluster {
        DuplicateCluster(
            id: "a",
            members: [
                person("a", "Maria", "Garcia", phones: [("mobile", "415-555-0001")], emails: ["m@example.com"], org: "Acme"),
                person("b", "Maria", "Garcia", phones: [("iPhone", "(415) 555-0001")], emails: ["m@example.com"], org: "Acme Corp", job: "CFO"),
                person("c", "Maria", "Garcia", emails: ["m@example.com", "other@example.com"]),
            ],
            confidence: 0.9, reasons: ["same email m@example.com", "same name"], flags: [],
            edges: [edge("a", "b", 0.95), edge("b", "c", 0.9), edge("a", "c", 0.9)],
            relatedEdges: [edge("c", "z", 0.4, flags: [.sharedPhoneDifferentNames], reasons: ["same phone +14155550100"])]
        )
    }

    @Test("A fresh draft mirrors the cluster and suggests the member with the most data as survivor")
    func initialState() {
        let draft = MergeDraft(cluster: threeMemberCluster())
        #expect(draft.members.map(\.id) == ["a", "b", "c"])
        #expect(draft.survivorID == "b")
        #expect(draft.survivor.id == "b")
        #expect(draft.confidence == 0.9 && draft.reasons.count == 2 && draft.flags.isEmpty)
        #expect(draft.canMerge && draft.removedMembers.isEmpty)
        #expect(draft.plan.deleteIDs == ["a", "c"])
        #expect(draft.deleteSourceIdentifiers == ["a", "c"])
    }

    @Test("Ties for most data go to the lowest id")
    func survivorTieBreak() {
        let members = [person("y", "A", "B", emails: ["a@b.com"]), person("x", "A", "B", emails: ["a@b.com"])]
        #expect(MergeDraft.suggestedSurvivor(in: members).id == "x")
    }

    @Test("Choosing a survivor changes what is kept and what is deleted; unknown ids are ignored")
    func chooseSurvivor() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        draft.chooseSurvivor("a")
        #expect(draft.survivorID == "a" && draft.plan.deleteIDs == ["b", "c"])
        draft.chooseSurvivor("nobody")
        #expect(draft.survivorID == "a")
    }

    @Test("Conflict rows stay stable after a pick; the preview follows the pick")
    func picks() throws {
        var draft = MergeDraft(cluster: threeMemberCluster())
        draft.chooseSurvivor("a")
        let fields = draft.conflicts.map(\.field)
        #expect(fields.contains(.organization) && fields.contains(.jobTitle) == false)
        #expect(draft.plan.merged.organization == "Acme")
        #expect(draft.selectedRecordID(for: .organization) == "a")

        draft.pick(.organization, recordID: "b")
        #expect(draft.conflicts.map(\.field) == fields)
        #expect(draft.selectedRecordID(for: .organization) == "b")
        #expect(draft.plan.merged.organization == "Acme Corp")
        #expect(draft.plan.merged.jobTitle == "CFO")
    }

    @Test("Picks naming a removed member are dropped")
    func picksForRemovedMember() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        draft.chooseSurvivor("a")
        draft.pick(.organization, recordID: "b")
        let removedB = draft.remove(memberID: "b")
        #expect(removedB)
        #expect(draft.picks[.organization] == nil)
        #expect(draft.plan.merged.organization == "Acme")
    }

    @Test("Dropped phone labels are surfaced by the plan")
    func droppedLabels() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        draft.chooseSurvivor("a")
        #expect(draft.plan.droppedLabels.contains { $0.field == .phones && $0.keptLabel == "mobile" && $0.droppedLabel == "iPhone" })
    }

    @Test("Removing a member re-scopes edges: its links become related edges and the cluster stats are recomputed")
    func removeMember() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        let removedC = draft.remove(memberID: "c")
        #expect(removedC)
        #expect(draft.members.map(\.id) == ["a", "b"])
        #expect(draft.removedMembers.map(\.id) == ["c"])
        #expect(draft.edges.map(\.secondID) == ["b"])
        // The removed member's links to the rest are now "possibly related"; its own outside link is not this cluster's business.
        #expect(Set(draft.relatedEdges.map { Set([$0.firstID, $0.secondID]) }) == [["a", "c"], ["b", "c"]])
        #expect(draft.confidence == 0.95)
        #expect(draft.survivor.id != "c" && !draft.plan.deleteIDs.contains("c"))
        #expect(draft.deleteSourceIdentifiers.count == 1)
    }

    @Test("A cluster of two cannot lose a member; a removed member can be restored")
    func removeLimitsAndRestore() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        let removedA = draft.remove(memberID: "a")
        #expect(removedA)
        let removedB = draft.remove(memberID: "b")
        #expect(!removedB)
        let removedNobody = draft.remove(memberID: "nobody")
        #expect(!removedNobody)
        #expect(draft.members.count == 2)
        draft.restore(memberID: "a")
        #expect(draft.members.map(\.id) == ["a", "b", "c"])
        #expect(draft.confidence == 0.9)
    }

    @Test("Removing the survivor moves the survivor to a remaining member")
    func removeSurvivor() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        #expect(draft.survivorID == "b")
        let removedB = draft.remove(memberID: "b")
        #expect(removedB)
        #expect(draft.survivorID == "a" || draft.survivorID == "c")
        #expect(draft.members.contains { $0.id == draft.survivorID })
    }

    @Test("Members joined only through a removed member are reported as separate components")
    func components() {
        var draft = MergeDraft(cluster: DuplicateCluster(
            id: "a",
            members: [person("a", "A", "X"), person("b", "A", "X"), person("c", "A", "X")],
            confidence: 0.7, reasons: [], flags: [],
            edges: [edge("a", "b", 0.9), edge("b", "c", 0.9)], relatedEdges: []
        ))
        #expect(draft.components == [["a", "b", "c"]])
        let removedB = draft.remove(memberID: "b")
        #expect(removedB)
        #expect(draft.components == [["a"], ["c"]])
        #expect(draft.isSplit)
        #expect(draft.confidence == nil)
    }

    @Test("Weak edges are the conflict-flagged or sub-medium links among the remaining members")
    func weakEdges() {
        let cluster = DuplicateCluster(
            id: "a", members: [person("a", "A", "X"), person("b", "A", "X"), person("c", "A", "X")],
            confidence: 0.35, reasons: [], flags: [.sharedPhoneDifferentNames],
            edges: [edge("a", "b", 0.9), edge("b", "c", 0.9), edge("a", "c", 0.35, flags: [.sharedPhoneDifferentNames])],
            relatedEdges: []
        )
        var draft = MergeDraft(cluster: cluster)
        #expect(draft.weakEdges.map { [$0.firstID, $0.secondID] } == [["a", "c"]])
        let removedC = draft.remove(memberID: "c")
        #expect(removedC)
        #expect(draft.weakEdges.isEmpty)
    }

    @Test("The combined note follows the survivor and the notes of the others, using NotesMerge")
    func combinedNote() {
        var draft = MergeDraft(cluster: threeMemberCluster())
        draft.chooseSurvivor("a")
        let notes = ["a": "Mine", "b": "Theirs", "c": "mine"]
        #expect(draft.combinedNote(notes: notes) == "Mine\n\nTheirs")
        #expect(draft.combinedNote(notes: [:]) == nil)
        #expect(draft.combinedNote(notes: ["b": "Only theirs"]) == "Only theirs")
    }

    @Test("Display names fall back from person name to organization to contact details")
    func displayNames() {
        #expect(person("1", "Ann", "Lee").displayName == "Ann Lee")
        #expect(ContactRecord(id: "2", source: .icloud, sourceIdentifier: "2", organization: "Acme").displayName == "Acme")
        #expect(ContactRecord(id: "3", source: .icloud, sourceIdentifier: "3", emails: [Labeled(label: nil, value: "x@y.com")]).displayName == "x@y.com")
        #expect(ContactRecord(id: "4", source: .icloud, sourceIdentifier: "4", phones: [Labeled(label: nil, value: "555")]).displayName == "555")
        #expect(ContactRecord(id: "5", source: .icloud, sourceIdentifier: "5").displayName == "(No name)")
        #expect(ContactRecord(id: "6", source: .icloud, sourceIdentifier: "6", givenName: "Ann", middleName: "B", familyName: "Lee").displayName == "Ann B Lee")
    }
}
