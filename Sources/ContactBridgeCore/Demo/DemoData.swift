import Foundation

/// Everything the app needs to run without touching real data: fakes seeded with sample contacts that exercise every
/// screen (clear duplicates, a household phone, a three-way cluster, conflicting fields, safe and tick-by-hand groups for bulk merge, Google-only contacts including a business and a text-message sender, other
/// contacts, a possible match, notes), for Clean up (text-message senders, nameless and empty contacts, imported contacts) and for the
/// Sync review list (after Start syncing: Leo edited in Google, Mia deleted in Google, David edited on both sides, Priya and others
/// new in Google, Janet a possible match for the Carters, Ann Lee a conflict from linking two contacts for the first time).
public struct DemoEnvironment: Sendable {
    public let store: InMemoryContactStore
    public let google: FakeGoogleClient
    public let notes: InMemoryNotesStore
    public let links: InMemoryLinkStore
    public let dismissals: InMemoryDismissalStore
    /// The sync files, in memory: the demo runs the real engine against the fakes above, and nothing reaches the disk.
    public let syncState: InMemorySyncStateStore
    public let reviews: InMemoryReviewStore
    public let journal: InMemorySyncJournalStore
    public let history: InMemorySyncHistoryStore
    public let containers: [ContactContainer]
    public let accountEmail: String
}

public enum DemoData {
    public static func make() -> DemoEnvironment {
        var counter = 0
        func icloud(
            _ given: String, _ family: String, phones: [(String, String)] = [], emails: [String] = [], org: String = "", job: String = ""
        ) -> ContactRecord {
            counter += 1
            let id = "demo-\(counter)"
            return ContactRecord(
                id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family, organization: org, jobTitle: job,
                phones: phones.map { Labeled(label: $0.0, value: $0.1) }, emails: emails.map { Labeled(label: "home", value: $0) }
            )
        }

        let book = [
            // Clear duplicate: same phone and name, labels and organization disagree.
            icloud("Ann", "Lee", phones: [("mobile", "415-555-2671")], emails: ["ann.lee@example.com"], org: "Northwind"),
            icloud("Ann", "Lee", phones: [("iPhone", "(415) 555-2671")], emails: ["ann@lee.example"], org: "Northwind Traders", job: "Designer"),
            // Nickname duplicate by email.
            icloud("Robert", "Smith", emails: ["bob.smith@example.com"]),
            icloud("Bob", "Smith", phones: [("work", "415-555-0111")], emails: ["bob.smith@example.com"]),
            // Household phone: one line, two people.
            icloud("John", "Carter", phones: [("home", "415-555-0142")], emails: ["john.carter@example.com"]),
            icloud("Jane", "Carter", phones: [("home", "415-555-0142")]),
            // Three records for one person.
            icloud("Maria", "Garcia", phones: [("mobile", "415-555-0177")], emails: ["maria.g@example.com"]),
            icloud("Maria", "Garcia", emails: ["maria.g@example.com"], org: "Garcia & Co"),
            icloud("Maria", "Garcia", phones: [("home", "415-555-0177")]),
            // Plain duplicates with nothing to decide: what "Select all safe groups" picks up.
            icloud("Liam", "OConnor", phones: [("mobile", "415-555-0211")], emails: ["liam.oconnor@example.com"]),
            icloud("Liam", "OConnor", phones: [("mobile", "(415) 555-0211")], emails: ["liam.oconnor@example.com"], org: "Harbor Logistics"),
            icloud("Sofia", "Martinez", phones: [("mobile", "415-555-0222")], emails: ["sofia.m@example.com"]),
            icloud("Sofia", "Martinez", phones: [("work", "415-555-0222")], emails: ["sofia.m@example.com"], job: "Architect"),
            icloud("Noah", "Kim", phones: [("mobile", "415-555-0233")]),
            icloud("Noah", "Kim", phones: [("home", "415-555-0233")], emails: ["noah.kim@example.com"]),
            // Same name but nothing shared to confirm it, and a person next to a nameless record on one phone: both are
            // likely matches that carry a caveat, so they can be ticked by hand but not by "Select all safe groups".
            icloud("Owen", "Hayes", phones: [("mobile", "415-555-0255")]),
            icloud("Owen", "Hayes", emails: ["owen.hayes@example.com"]),
            icloud("Priscilla", "Wong", phones: [("mobile", "415-555-0266")], emails: ["priscilla.wong@example.com"]),
            icloud("", "", phones: [("work", "415-555-0266")], org: "Wong Bakery"),
            // Not duplicates of anything.
            icloud("Carol", "White", phones: [("mobile", "415-555-0190")], emails: ["carol@example.com"]),
            // Edited on both sides since the last sync (see the seeded baselines below): his company differs in iCloud and Google.
            icloud("David", "Brown", phones: [("mobile", "415-555-0123")], emails: ["david.brown@example.com"], org: "Brown & Co"),
            icloud("Emma", "Stone", emails: ["emma.stone@example.com"]),
            // Clean up: automated text-message senders (short-code phones, no person name), one of them with no name at all.
            icloud("", "", phones: [("mobile", "72727")], org: "Acme Rewards"),
            icloud("", "", phones: [("mobile", "32665")], org: "Harbor Bank Alerts"),
            icloud("", "", phones: [("mobile", "227898")]),
            // A phone number with nothing else, a person and a business with no way to reach them, and an empty card.
            icloud("", "", phones: [("mobile", "415-555-0300")]),
            icloud("Henry", "Walsh"),
            icloud("", "", org: "Walsh Plumbing"),
            icloud("", ""),
            // Created by a Contact Bridge import: linked to their Google contact below.
            icloud("Leo", "Fischer", phones: [("mobile", "415-555-0401"), ("home", "415-555-0402")], emails: ["leo.fischer@example.com"]),
            icloud("Mia", "Chen", emails: ["mia.chen@example.com"]),
        ]

        func googlePerson(
            _ given: String, _ family: String, phones: [String] = [], emails: [String] = [], org: String = ""
        ) -> GooglePerson {
            GooglePersonMapper.createPayload(for: ContactRecord(
                id: "x", source: .google, sourceIdentifier: "x", givenName: given, familyName: family, organization: org,
                phones: phones.map { Labeled(label: "mobile", value: $0) }, emails: emails.map { Labeled(label: "home", value: $0) }
            ))
        }

        /// A Google contact with labelled entries, as it would be listed (resource name and etag come from the fake).
        func labelledPerson(
            _ given: String, _ family: String, phones: [(String, String)] = [], emails: [(String, String)] = [], org: String = "", job: String = ""
        ) -> GooglePerson {
            GooglePersonMapper.createPayload(for: ContactRecord(
                id: "x", source: .google, sourceIdentifier: "x", givenName: given, familyName: family, organization: org, jobTitle: job,
                phones: phones.map { Labeled(label: $0.0, value: $0.1) }, emails: emails.map { Labeled(label: $0.0, value: $0.1) }
            ))
        }

        // What the Google contacts of Leo and David looked like at the last sync, and what they say now. Leo was edited in
        // Google only; David was edited in iCloud (company "Brown & Co") and in Google (company "Brown Consulting").
        let leoThen = labelledPerson(
            "Leo", "Fischer", phones: [("mobile", "415-555-0401"), ("home", "415-555-0402")],
            emails: [("home", "leo.fischer@example.com"), ("work", "leo@fischerdesign.example")]
        )
        let leoNow = labelledPerson(
            "Leo", "Fischer", phones: [("mobile", "415-555-0401")],
            emails: [("home", "leo.fischer@example.com"), ("work", "leo@fischerdesign.example"), ("home", "leo.f@gmail.example")],
            org: "Fischer Design", job: "Creative Director"
        )
        let davidThen = labelledPerson("David", "Brown", phones: [("mobile", "415-555-0123")], emails: [("home", "david.brown@example.com")])
        let davidNow = labelledPerson(
            "David", "Brown", phones: [("mobile", "415-555-0123")], emails: [("home", "david.brown@example.com")], org: "Brown Consulting"
        )

        // Mia was imported and then deleted in Google: her link stays and points at a contact that is no longer listed.
        let miaResource = "people/c99999"
        let connections = [
            googlePerson("Ann", "Lee", phones: ["+1 415 555 2671"], emails: ["ann.lee@example.com"]), // already in iCloud
            davidNow, // imported earlier, edited on both sides since
            googlePerson("Priya", "Patel", phones: ["415-555-0301"], emails: ["priya@example.com"]), // new
            googlePerson("Tom", "Nguyen", emails: ["tom.nguyen@example.com"]), // new
            googlePerson("Janet", "Carter", emails: ["john.carter@example.com"]), // new, but resembles the Carters
            leoNow, // imported earlier, edited in Google since
            googlePerson("", "", phones: ["415-555-0302"], emails: ["front.desk@lakesidedental.example"], org: "Lakeside Dental"), // new, a business
            googlePerson("", "", phones: ["48012"], org: "Parcel Express Alerts"), // new, a text-message sender
        ].enumerated().map { index, person in
            var person = person
            person.resourceName = "people/c\(index + 1)"
            return person
        }
        let others = [
            googlePerson("Sam", "Rivera", emails: ["sam.rivera@example.com"]),
            googlePerson("Dana", "Kim", emails: ["dana.kim@example.com"]),
            googlePerson("Maria", "Garcia", emails: ["maria.g@example.com"]), // already in iCloud
        ]

        let notes = [
            book[0].id: "Met at the 2024 design conference.",
            book[1].id: "Prefers email over phone.",
            book[4].id: "Shares the home line with Jane.",
            book[6].id: "Send a birthday card.",
        ]

        // Past imports, so the Imported filter in Clean up shows something. In-memory, so adding cannot fail.
        let links = InMemoryLinkStore()
        let imported = [("Mia", miaResource), ("Leo", "people/c6"), ("David", "people/c2")].compactMap { given, resource in
            book.first { $0.givenName == given }.map { ImportedLink(icloudID: $0.sourceIdentifier, googleResourceName: resource) }
        }
        try? links.add(imported, at: Date(timeIntervalSince1970: 1_790_000_000))

        // Leo and David have synced before, so Start syncing finds their edits as ordinary changes rather than as two
        // contacts to compare for the first time. A baseline's etag is one the fake never issues, so Google's copy reads as edited.
        func googleRecord(_ person: GooglePerson, _ resource: String) -> ContactRecord {
            var person = person
            person.resourceName = resource
            return GooglePersonMapper.record(from: person) ?? ContactRecord(id: resource, source: .google, sourceIdentifier: resource)
        }
        func baseline(_ name: String, icloud: ContactRecord, google: ContactRecord) -> (String, SyncBaseline) {
            (icloud.sourceIdentifier, SyncBaseline(
                icloud: icloud, google: google, googleEtag: "demo-synced-\(name)", icloudNoteHash: NoteHash.hash(""),
                googleNoteHash: NoteHash.hash(""), syncedAt: Date(timeIntervalSince1970: 1_790_000_000)
            ))
        }
        /// The iCloud contact as it was at the last sync: without the company it has now.
        func iCloudThen(_ given: String) -> ContactRecord {
            var record = book.first { $0.givenName == given } ?? ContactRecord(id: "", source: .icloud, sourceIdentifier: "")
            record.organization = ""
            return record
        }
        let baselines = Dictionary(uniqueKeysWithValues: [
            baseline("leo", icloud: iCloudThen("Leo"), google: googleRecord(leoThen, "people/c6")),
            baseline("david", icloud: iCloudThen("David"), google: googleRecord(davidThen, "people/c2")),
        ])

        return DemoEnvironment(
            store: InMemoryContactStore(records: book),
            google: FakeGoogleClient(people: connections, otherContacts: others),
            notes: InMemoryNotesStore(notes: notes),
            links: links,
            dismissals: InMemoryDismissalStore(),
            syncState: InMemorySyncStateStore(SyncState(baselines: baselines)),
            reviews: InMemoryReviewStore(),
            journal: InMemorySyncJournalStore(),
            history: InMemorySyncHistoryStore(),
            containers: [ContactContainer(id: "demo-icloud", name: "iCloud", kind: .cardDAV, isDefault: true)],
            accountEmail: "demo.user@example.com"
        )
    }
}
