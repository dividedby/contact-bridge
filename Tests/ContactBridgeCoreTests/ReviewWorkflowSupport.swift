import Foundation
import Testing
@testable import ContactBridgeCore

/// An `ExecutorRig`'s world and stores with the review workflows on top, sharing one write gate.
final class ReviewRig: @unchecked Sendable {
    let base: ExecutorRig
    let gate = WriteGate()
    let workflows: ReviewWorkflows

    init(_ base: ExecutorRig, notes: Bool = true) {
        self.base = base
        let clock = base.clock
        workflows = ReviewWorkflows(
            store: base.world.store, google: base.faulty, notes: notes ? base.world.notes : nil, backups: base.backups,
            links: base.linkStore, state: base.stateStore, reviews: base.reviews, journal: base.journal, history: base.history,
            gate: gate, now: { clock.now() }
        )
    }

    /// Six synced contacts, approved.
    static func linked(count: Int = 6, notes: Bool = true) async throws -> ReviewRig {
        ReviewRig(try await ExecutorRig.linked(count: count), notes: notes)
    }

    /// A first sync of whatever the world holds, already approved, so its plan runs.
    static func firstSync(_ world: SyncWorld) throws -> ReviewRig {
        world.state.firstSyncApproved = true
        return ReviewRig(try ExecutorRig(world))
    }

    var world: SyncWorld { base.world }
    var state: SyncState { get throws { try base.state } }
    var storedItems: [ReviewItem] { get throws { try base.reviews.load() } }

    /// One sync run without the engine ("Sync now": notes are read): plan, file the review items, execute.
    @discardableResult
    func syncOnce() async throws -> SyncRunReport {
        let plan = try await base.plan(.syncNow)
        _ = try base.reviews.reconcile(with: plan, ignoredGoogle: try state.ignoredGoogle, at: base.clock.now())
        return try await base.run(plan)
    }

    func item(_ id: String) throws -> ReviewItem { try #require(try storedItems.first { $0.id == id }) }

    func detail(_ id: String) async throws -> ReviewDetail { try await workflows.loadDetail(try item(id)) }

    func icloud(_ id: String) async throws -> ContactRecord { try #require(try await world.icloudRecord(id)) }

    /// A plan made now should have nothing to do: no echo of what the user just decided.
    func expectSettled(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let plan = try await base.plan()
        #expect(plan.isEmpty, comment, sourceLocation: sourceLocation)
        #expect(plan.updates.isEmpty && plan.review.isEmpty && plan.baselineRefreshes.isEmpty, sourceLocation: sourceLocation)
    }

    func cleanUp() { base.cleanUp() }
}
