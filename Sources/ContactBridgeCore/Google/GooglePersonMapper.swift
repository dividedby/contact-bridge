import Foundation

/// The result of `GooglePersonMapper.updatePayload`: send `person` (with its etag) and `updatePersonFields` together.
public struct GoogleUpdatePayload: Sendable, Hashable {
    public var resourceName: String?
    public var person: GooglePerson
    public var updatePersonFields: String
}

/// Ownership tag stored in a Google contact's `clientData`: the iCloud identifier of the contact it was created from.
public enum GoogleOwnership {
    public static let clientDataKey = "contactBridge.sourceID"

    public static func sourceID(of person: GooglePerson) -> String? {
        person.clientData?.first { $0.key == clientDataKey }?.value
    }

    /// Sets (or, with nil, removes) the tag, leaving other clients' entries alone.
    public static func setSourceID(_ id: String?, on person: inout GooglePerson) {
        var entries = (person.clientData ?? []).filter { $0.key != clientDataKey }
        if let id { entries.append(GoogleClientData(key: clientDataKey, value: id)) }
        person.clientData = entries.isEmpty ? nil : entries
    }
}

extension GooglePerson {
    public var contactBridgeSourceID: String? { GoogleOwnership.sourceID(of: self) }
}

/// Person <-> ContactRecord. Source is `.google` (connections) or `.googleOther` (other contacts); the record's id and
/// sourceIdentifier are both the resource name.
///
/// Only entries that belong to the contact itself are read or written: entries Google merges in from a profile or a
/// domain directory (`metadata.source.type` other than CONTACT / OTHER_CONTACT) are read-only and are skipped
/// everywhere, so they are never copied into the contact.
///
/// Updates use `updatePersonFields` masks covering only modeled fields, and the payload is built from the person as last
/// fetched. Each fetched entry keeps its unmodeled keys (`extras`: job descriptions, phonetic names, PO boxes, future
/// fields) and only the modeled keys are overlaid on it. Unchanged entries are reused as fetched; an edited phone, email,
/// url or address is paired with the fetched entry of the same label. Not carried over: output-only fields that the edit
/// invalidates (canonical forms, formatted values), and entries of a changed label (a relabelled address is a new entry).
public enum GooglePersonMapper {
    static let modeledFields = [
        "names", "nicknames", "organizations", "phoneNumbers", "emailAddresses", "addresses", "urls", "birthdays",
    ]

    public static func updatePersonFields(includingOwnershipTag: Bool) -> String {
        (modeledFields + (includingOwnershipTag ? ["clientData"] : [])).joined(separator: ",")
    }

    /// Entries from the contact itself (or an other-contact). Profile and domain entries are read-only.
    static func isContactSourced<T: GoogleMetadataCarrying>(_ item: T) -> Bool {
        switch item.metadata?.source?.type {
        case nil, "CONTACT", "OTHER_CONTACT": true
        default: false
        }
    }

    private static func contactSourced<T: GoogleMetadataCarrying>(_ items: [T]?) -> [T] {
        (items ?? []).filter(isContactSourced)
    }

    // MARK: Person -> ContactRecord

    /// Nil for deleted-person sync stubs and people without a resource name.
    public static func record(from person: GooglePerson, source: ContactSource = .google) -> ContactRecord? {
        guard let resourceName = person.resourceName, !person.isDeleted else { return nil }
        let name = primary(contactSourced(person.names))
        let organization = primary(contactSourced(person.organizations))
        return ContactRecord(
            id: resourceName,
            source: source,
            sourceIdentifier: resourceName,
            givenName: name?.givenName ?? "",
            middleName: name?.middleName ?? "",
            familyName: name?.familyName ?? "",
            nickname: primary(contactSourced(person.nicknames))?.value ?? "",
            organization: organization?.name ?? "",
            jobTitle: organization?.title ?? "",
            phones: contactSourced(person.phoneNumbers).compactMap(labeledPhone),
            emails: contactSourced(person.emailAddresses).compactMap(labeledEmail),
            postalAddresses: contactSourced(person.addresses).compactMap(labeledAddress),
            urls: contactSourced(person.urls).compactMap(labeledURL),
            birthday: birthday(contactSourced(person.birthdays))
        )
    }

    /// The contact's note: the `biographies` entries from the contact itself (read through `extras`, since the person
    /// model does not declare them), joined by a blank line if there are several. Empty when there is none.
    public static func note(of person: GooglePerson) -> String {
        guard case .array(let entries)? = person.extras["biographies"] else { return "" }
        return entries.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .string(let value)? = fields["value"], !value.isBlank else { return nil }
            if case .object(let metadata)? = fields["metadata"], case .object(let source)? = metadata["source"],
               case .string(let type)? = source["type"], type != "CONTACT", type != "OTHER_CONTACT" {
                return nil
            }
            return value
        }.joined(separator: "\n\n")
    }

    /// `NoteHash.hash` of `note(of:)`. A person without biographies is a known empty note, never unknown.
    public static func noteHash(of person: GooglePerson) -> String { NoteHash.hash(note(of: person)) }

    private static func primary<T: GoogleMetadataCarrying>(_ items: [T]) -> T? {
        items.first { $0.metadata?.primary == true } ?? items.first
    }

    private static func labeledPhone(_ phone: GooglePhoneNumber) -> Labeled<String>? {
        phone.value.map { Labeled(label: friendlyLabel(phone.type), value: $0) }
    }

    private static func labeledEmail(_ email: GoogleEmailAddress) -> Labeled<String>? {
        email.value.map { Labeled(label: friendlyLabel(email.type), value: $0) }
    }

    private static func labeledURL(_ url: GoogleUrl) -> Labeled<String>? {
        url.value.map { Labeled(label: friendlyLabel(url.type), value: $0) }
    }

    private static func labeledAddress(_ address: GoogleAddress) -> Labeled<PostalAddress>? {
        let mapped = PostalAddress(
            street: [address.streetAddress, address.extendedAddress].compactMap { $0 }.filter { !$0.isBlank }.joined(separator: "\n"),
            city: address.city ?? "",
            state: address.region ?? "",
            postalCode: address.postalCode ?? "",
            country: address.country ?? "",
            isoCountryCode: address.countryCode.flatMap { $0.isBlank ? nil : $0.lowercased() }
        )
        return mapped.isEmpty ? nil : Labeled(label: friendlyLabel(address.type), value: mapped)
    }

    private static func datedBirthdays(_ birthdays: [GoogleBirthday]) -> [GoogleBirthday] {
        birthdays.filter { $0.date?.month != nil && $0.date?.day != nil }
    }

    private static func birthday(_ birthdays: [GoogleBirthday]) -> DateComponents? {
        guard let date = primary(datedBirthdays(birthdays))?.date, let month = date.month, let day = date.day else { return nil }
        let year = date.year.flatMap { $0 > 0 ? $0 : nil }
        return DateComponents(year: year, month: month, day: day)
    }

    // MARK: ContactRecord -> Person

    /// A new contact: modeled fields only, no identity, etag or metadata.
    public static func createPayload(for record: ContactRecord, ownershipSourceID: String? = nil) -> GooglePerson {
        var person = GooglePerson()
        if hasName(record) { person.names = [applyName(record, to: GoogleName())] }
        if !record.nickname.isBlank { person.nicknames = [GoogleNickname(value: record.nickname)] }
        if hasOrganization(record) { person.organizations = [applyOrganization(record, to: GoogleOrganization())] }
        person.phoneNumbers = nonEmpty(record.phones.filter { !$0.value.isBlank }.map(makePhone))
        person.emailAddresses = nonEmpty(record.emails.filter { !$0.value.isBlank }.map(makeEmail))
        person.addresses = nonEmpty(record.postalAddresses.filter { !$0.value.isEmpty }.map(makeAddress))
        person.urls = nonEmpty(record.urls.filter { !$0.value.isBlank }.map(makeURL))
        person.birthdays = makeBirthdays(record.birthday)
        if let ownershipSourceID { GoogleOwnership.setSourceID(ownershipSourceID, on: &person) }
        return person
    }

    /// Edits `existing` (the person as last fetched) to match `record`. See the type's notes on what is preserved.
    public static func updatePayload(
        for record: ContactRecord, existing: GooglePerson, ownershipSourceID: String? = nil
    ) -> GoogleUpdatePayload {
        var person = GooglePerson(resourceName: existing.resourceName, etag: existing.etag)

        person.names = updatedPrimary(
            existing.names, wanted: hasName(record), make: { applyName(record, to: $0) }, clean: cleanName
        )
        person.nicknames = updatedPrimary(
            existing.nicknames, wanted: !record.nickname.isBlank,
            make: { var nickname = $0; nickname.value = record.nickname; return nickname }, clean: { $0 }
        )
        person.organizations = updatedPrimary(
            existing.organizations, wanted: hasOrganization(record), make: { applyOrganization(record, to: $0) },
            clean: { var org = $0; org.formattedType = nil; return org }
        )

        person.phoneNumbers = reconcile(
            existing: existing.phoneNumbers, desired: record.phones.filter { !$0.value.isBlank },
            matches: { sameLabel(friendlyLabel($0.type), $1.label) && $0.value == $1.value },
            label: { friendlyLabel($0.type) }, overlay: overlayPhone, make: makePhone
        )
        person.emailAddresses = reconcile(
            existing: existing.emailAddresses, desired: record.emails.filter { !$0.value.isBlank },
            matches: { sameLabel(friendlyLabel($0.type), $1.label) && $0.value == $1.value },
            label: { friendlyLabel($0.type) }, overlay: overlayEmail, make: makeEmail
        )
        person.addresses = reconcile(
            existing: existing.addresses, desired: record.postalAddresses.filter { !$0.value.isEmpty },
            matches: addressMatches, label: { friendlyLabel($0.type) }, overlay: overlayAddress, make: makeAddress
        )
        person.urls = reconcile(
            existing: existing.urls, desired: record.urls.filter { !$0.value.isBlank },
            matches: { sameLabel(friendlyLabel($0.type), $1.label) && $0.value == $1.value },
            label: { friendlyLabel($0.type) }, overlay: overlayURL, make: makeURL
        )

        // A text-only Google birthday ("March 9th") has no date to map: leave the field out of the mask unless the
        // record gives it a real birthday.
        var fields = modeledFields
        let contactBirthdays = contactSourced(existing.birthdays)
        let dated = datedBirthdays(contactBirthdays)
        if let date = makeBirthdays(record.birthday)?.first?.date {
            var entry = primary(dated) ?? contactBirthdays.first ?? GoogleBirthday()
            entry.date = date
            entry.text = nil
            person.birthdays = [withoutMetadata(entry)]
        } else if dated.isEmpty {
            fields.removeAll { $0 == "birthdays" }
        } else {
            person.birthdays = nonEmpty(contactBirthdays.filter { !dated.contains($0) }.map(withoutMetadata))
        }

        if let ownershipSourceID {
            person.clientData = existing.clientData
            GoogleOwnership.setSourceID(ownershipSourceID, on: &person)
            fields.append("clientData")
        }
        return GoogleUpdatePayload(
            resourceName: existing.resourceName, person: person, updatePersonFields: fields.joined(separator: ",")
        )
    }

    /// `updatePayload` limited to the given groups: the payload and `updatePersonFields` carry only those, so a sync
    /// write for one edited field cannot touch or race on the rest. `clientData` joins the mask when the ownership tag
    /// is wanted and `existing` does not carry it yet.
    ///
    /// `.note` is written as `biographies` only when `note` is given: nil means the note is unknown and is left out of
    /// the payload and mask, so an unreadable note cannot erase Google's. A blank `note` is a known empty note and
    /// clears `biographies` (the mask names it, the payload omits it). The mask is empty if nothing qualifies; do not
    /// send it.
    public static func updatePayload(
        for record: ContactRecord, existing: GooglePerson, ownershipSourceID: String? = nil,
        restrictedTo fields: Set<SyncField>, note: String? = nil
    ) -> GoogleUpdatePayload {
        let full = updatePayload(for: record, existing: existing)
        let fullMask = Set(full.updatePersonFields.split(separator: ",").map(String.init))
        var person = GooglePerson(resourceName: existing.resourceName, etag: existing.etag)
        var mask: [String] = []

        for field in SyncField.recordFields where fields.contains(field) && fullMask.contains(field.peopleAPIField) {
            switch field {
            case .name: person.names = full.person.names
            case .nickname: person.nicknames = full.person.nicknames
            case .organization: person.organizations = full.person.organizations
            case .phones: person.phoneNumbers = full.person.phoneNumbers
            case .emails: person.emailAddresses = full.person.emailAddresses
            case .postalAddresses: person.addresses = full.person.addresses
            case .urls: person.urls = full.person.urls
            case .birthday: person.birthdays = full.person.birthdays
            case .note: break
            }
            mask.append(field.peopleAPIField)
        }

        if fields.contains(.note), let note {
            setNote(note, on: &person)
            mask.append(SyncField.note.peopleAPIField)
        }

        if let ownershipSourceID, GoogleOwnership.sourceID(of: existing) != ownershipSourceID {
            person.clientData = existing.clientData
            GoogleOwnership.setSourceID(ownershipSourceID, on: &person)
            mask.append("clientData")
        }
        return GoogleUpdatePayload(resourceName: existing.resourceName, person: person, updatePersonFields: mask.joined(separator: ","))
    }

    /// Sets `biographies` to the note as plain text. A blank note sets nothing.
    public static func setNote(_ note: String, on person: inout GooglePerson) {
        guard !note.isBlank else { return }
        person.extras["biographies"] = .array([.object(["value": .string(note), "contentType": .string("TEXT_PLAIN")])])
    }

    // MARK: building entries

    private static func hasName(_ record: ContactRecord) -> Bool {
        !(record.givenName.isBlank && record.middleName.isBlank && record.familyName.isBlank)
    }

    private static func hasOrganization(_ record: ContactRecord) -> Bool {
        !(record.organization.isBlank && record.jobTitle.isBlank)
    }

    private static func nilIfBlank(_ text: String) -> String? { text.isBlank ? nil : text }

    private static func nonEmpty<T>(_ items: [T]) -> [T]? { items.isEmpty ? nil : items }

    private static func applyName(_ record: ContactRecord, to name: GoogleName) -> GoogleName {
        var name = name
        name.givenName = nilIfBlank(record.givenName)
        name.middleName = nilIfBlank(record.middleName)
        name.familyName = nilIfBlank(record.familyName)
        return name
    }

    private static func cleanName(_ name: GoogleName) -> GoogleName {
        var name = name
        name.displayName = nil
        name.displayNameLastFirst = nil
        name.unstructuredName = nil
        return name
    }

    private static func applyOrganization(_ record: ContactRecord, to organization: GoogleOrganization) -> GoogleOrganization {
        var organization = organization
        organization.name = nilIfBlank(record.organization)
        organization.title = nilIfBlank(record.jobTitle)
        return organization
    }

    private static func makePhone(_ phone: Labeled<String>) -> GooglePhoneNumber {
        GooglePhoneNumber(value: phone.value, type: googleType(phone.label))
    }

    private static func makeEmail(_ email: Labeled<String>) -> GoogleEmailAddress {
        GoogleEmailAddress(value: email.value, type: googleType(email.label))
    }

    private static func makeURL(_ url: Labeled<String>) -> GoogleUrl {
        GoogleUrl(value: url.value, type: googleType(url.label))
    }

    private static func makeAddress(_ entry: Labeled<PostalAddress>) -> GoogleAddress {
        let address = entry.value
        let lines = address.street.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return GoogleAddress(
            type: googleType(entry.label),
            streetAddress: nilIfBlank(lines.first ?? ""),
            extendedAddress: lines.count > 1 ? nilIfBlank(lines[1]) : nil,
            city: nilIfBlank(address.city),
            region: nilIfBlank(address.state),
            postalCode: nilIfBlank(address.postalCode),
            country: nilIfBlank(address.country),
            countryCode: address.isoCountryCode.flatMap(nilIfBlank)?.uppercased()
        )
    }

    private static func makeBirthdays(_ birthday: DateComponents?) -> [GoogleBirthday]? {
        guard let birthday, let month = birthday.month, let day = birthday.day else { return nil }
        return [GoogleBirthday(date: GoogleDate(year: birthday.year, month: month, day: day))]
    }

    // MARK: overlays (edit a fetched entry, keeping its unmodeled keys)

    /// Keeps `type` when the label is unchanged (case-insensitively); otherwise retypes and drops the stale formatted type.
    private static func retype(_ type: inout String?, _ formattedType: inout String?, to label: String?) {
        guard !sameLabel(friendlyLabel(type), label) else { return }
        type = googleType(label)
        formattedType = nil
    }

    private static func overlayPhone(_ entry: GooglePhoneNumber, _ wanted: Labeled<String>) -> GooglePhoneNumber {
        var entry = entry
        if entry.value != wanted.value {
            entry.value = wanted.value
            entry.canonicalForm = nil
        }
        retype(&entry.type, &entry.formattedType, to: wanted.label)
        return entry
    }

    private static func overlayEmail(_ entry: GoogleEmailAddress, _ wanted: Labeled<String>) -> GoogleEmailAddress {
        var entry = entry
        if entry.value != wanted.value {
            entry.value = wanted.value
            entry.displayName = nil
        }
        retype(&entry.type, &entry.formattedType, to: wanted.label)
        return entry
    }

    private static func overlayURL(_ entry: GoogleUrl, _ wanted: Labeled<String>) -> GoogleUrl {
        var entry = entry
        entry.value = wanted.value
        retype(&entry.type, &entry.formattedType, to: wanted.label)
        return entry
    }

    private static func overlayAddress(_ entry: GoogleAddress, _ wanted: Labeled<PostalAddress>) -> GoogleAddress {
        let made = makeAddress(wanted)
        var entry = entry
        entry.streetAddress = made.streetAddress
        entry.extendedAddress = made.extendedAddress
        entry.city = made.city
        entry.region = made.region
        entry.postalCode = made.postalCode
        entry.country = made.country
        entry.countryCode = made.countryCode ?? entry.countryCode
        entry.formattedValue = nil
        // poBox and unknown keys stay as fetched.
        retype(&entry.type, &entry.formattedType, to: wanted.label)
        return entry
    }

    /// Same five display fields and case-folded ISO code. Sub-locality and sub-administrative area are ignored: they
    /// exist on the Apple side only.
    private static func addressMatches(_ entry: GoogleAddress, _ wanted: Labeled<PostalAddress>) -> Bool {
        guard let have = labeledAddress(entry), sameLabel(have.label, wanted.label) else { return false }
        let a = have.value
        let b = wanted.value
        return a.street == b.street && a.city == b.city && a.state == b.state && a.postalCode == b.postalCode
            && a.country == b.country && a.isoCountryCode?.lowercased() == b.isoCountryCode?.lowercased()
    }

    // MARK: update helpers

    /// Edits the primary contact-sourced entry of a list the record models as a single value, keeping the other
    /// contact-sourced entries. Read-only entries are dropped.
    private static func updatedPrimary<T: GoogleMetadataCarrying>(
        _ existing: [T]?, wanted: Bool, make: (T) -> T, clean: (T) -> T
    ) -> [T]? where T: GoogleDefaultInit {
        var entries = contactSourced(existing)
        let index = entries.firstIndex { $0.metadata?.primary == true } ?? (entries.isEmpty ? nil : 0)
        var primary: T?
        if let index { primary = entries.remove(at: index) }
        if wanted {
            let base = primary ?? T()
            primary = make(base)
        } else {
            primary = nil
        }
        let all = ([primary].compactMap { $0 } + entries).map(clean).map(withoutMetadata)
        return nonEmpty(all)
    }

    private static func withoutMetadata<T: GoogleMetadataCarrying>(_ item: T) -> T {
        var item = item
        item.metadata = nil
        return item
    }

    /// Reuses fetched entries equal to a wanted one, overlays edits on the fetched entry with the same label, and builds
    /// the rest from scratch. Only contact-sourced entries take part.
    private static func reconcile<Entry: GoogleMetadataCarrying, Value: Sendable & Hashable & Codable>(
        existing: [Entry]?, desired: [Labeled<Value>],
        matches: (Entry, Labeled<Value>) -> Bool,
        label: (Entry) -> String?,
        overlay: (Entry, Labeled<Value>) -> Entry,
        make: (Labeled<Value>) -> Entry
    ) -> [Entry]? {
        var unused = contactSourced(existing)
        var chosen = [Entry?](repeating: nil, count: desired.count)
        for (index, wanted) in desired.enumerated() {
            if let match = unused.firstIndex(where: { matches($0, wanted) }) { chosen[index] = unused.remove(at: match) }
        }
        for (index, wanted) in desired.enumerated() where chosen[index] == nil {
            if let match = unused.firstIndex(where: { sameLabel(label($0), wanted.label) }) {
                chosen[index] = overlay(unused.remove(at: match), wanted)
            }
        }
        let entries = desired.enumerated().map { index, wanted in chosen[index] ?? make(wanted) }
        return nonEmpty(entries.map(withoutMetadata))
    }

    // MARK: labels

    private static func sameLabel(_ a: String?, _ b: String?) -> Bool {
        func key(_ label: String?) -> String? {
            guard let label, !label.isBlank else { return nil }
            return label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return key(a) == key(b)
    }

    private static let friendlyByType: [String: String] = [
        "homeFax": "home fax", "workFax": "work fax", "otherFax": "other fax",
        "workMobile": "work mobile", "workPager": "work pager", "googleVoice": "google voice",
        "homePage": "homepage",
    ]

    private static let typeByFriendly: [String: String] = {
        Dictionary(uniqueKeysWithValues: friendlyByType.map { ($0.value, $0.key) })
    }()

    /// People API types (`homeFax`) become the plain names the Apple side uses ("home fax"); custom types pass through.
    static func friendlyLabel(_ type: String?) -> String? {
        guard let type, !type.isBlank else { return nil }
        return friendlyByType[type] ?? type
    }

    static func googleType(_ friendly: String?) -> String? {
        guard let friendly, !friendly.isBlank else { return nil }
        let key = friendly.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let type = typeByFriendly[key] { return type }
        return Self.standardTypes.contains(key) ? key : friendly
    }

    /// Types spelled the same as their friendly name; matched case-insensitively.
    private static let standardTypes: Set<String> = [
        "mobile", "home", "work", "other", "main", "pager", "blog", "profile", "ftp", "reservations",
    ]
}

/// Entries `updatedPrimary` may need to create from scratch.
protocol GoogleDefaultInit {
    init()
}

extension GoogleName: GoogleDefaultInit {}
extension GoogleNickname: GoogleDefaultInit {}
extension GoogleOrganization: GoogleDefaultInit {}
