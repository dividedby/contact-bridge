import Contacts
import Foundation

/// Hand-rolled vCard 3.0 writer, used when `CNContactVCardSerialization` refuses a fetch with
/// `CNError.unauthorizedKeys` (its required keys include the entitlement-gated note key). Writes every field the merge
/// path fetches (`CNContactMapper.mergeKeys`) and no notes (they live outside CNContact; see `ContactsAppNotesProvider`). Fields a contact was not fetched with are skipped.
///
/// Conventions follow Apple's own exports so Contacts and `CNContactVCardSerialization.contacts(with:)` read them back:
/// custom labels use `itemN.X-ABLabel`, year-less birthdays use `X-APPLE-OMIT-YEAR=1604`.
enum VCardWriter {
    static func data(for contacts: [CNContact]) -> Data {
        Data(contacts.flatMap(card).map(fold).joined(separator: "\r\n").utf8 + (contacts.isEmpty ? [] : Array("\r\n".utf8)))
    }

    // MARK: card

    private static func card(for contact: CNContact) -> [String] {
        func has(_ key: String) -> Bool { contact.isKeyAvailable(key) }
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        var groups = 0
        func nextGroup() -> String {
            groups += 1
            return "item\(groups)"
        }

        let prefix = has(CNContactNamePrefixKey) ? contact.namePrefix : ""
        let suffix = has(CNContactNameSuffixKey) ? contact.nameSuffix : ""
        let name = [contact.givenName, contact.middleName, contact.familyName]
        lines.append("N:" + [contact.familyName, contact.givenName, contact.middleName, prefix, suffix].map(escape).joined(separator: ";"))
        let display = ([prefix] + name + [suffix]).filter { !$0.isBlank }.joined(separator: " ")
        lines.append("FN:" + escape(display.isEmpty ? contact.organizationName : display))

        if !contact.nickname.isBlank { lines.append("NICKNAME:" + escape(contact.nickname)) }
        let department = has(CNContactDepartmentNameKey) ? contact.departmentName : ""
        if !contact.organizationName.isBlank || !department.isBlank {
            let parts = department.isBlank ? [contact.organizationName] : [contact.organizationName, department]
            lines.append("ORG:" + parts.map(escape).joined(separator: ";"))
        }
        if !contact.jobTitle.isBlank { lines.append("TITLE:" + escape(contact.jobTitle)) }
        if has(CNContactPhoneticGivenNameKey), !contact.phoneticGivenName.isBlank {
            lines.append("X-PHONETIC-FIRST-NAME:" + escape(contact.phoneticGivenName))
        }
        if has(CNContactPhoneticMiddleNameKey), !contact.phoneticMiddleName.isBlank {
            lines.append("X-PHONETIC-MIDDLE-NAME:" + escape(contact.phoneticMiddleName))
        }
        if has(CNContactPhoneticFamilyNameKey), !contact.phoneticFamilyName.isBlank {
            lines.append("X-PHONETIC-LAST-NAME:" + escape(contact.phoneticFamilyName))
        }
        if has(CNContactPhoneticOrganizationNameKey), !contact.phoneticOrganizationName.isBlank {
            lines.append("X-PHONETIC-ORG:" + escape(contact.phoneticOrganizationName))
        }
        if has(CNContactPreviousFamilyNameKey), !contact.previousFamilyName.isBlank {
            lines.append("X-PREVIOUS-FAMILY-NAME:" + escape(contact.previousFamilyName))
        }

        func labeled(_ property: String, label: String?, params: [String] = [], value: String) {
            let (types, custom) = typeParameters(property: property, label: label)
            let allParams = (params + types.map { "TYPE=\($0)" }).map { ";" + $0 }.joined()
            if let custom {
                let group = nextGroup()
                lines.append("\(group).\(property)\(allParams):\(value)")
                lines.append("\(group).X-ABLabel:\(escape(custom))")
            } else {
                lines.append("\(property)\(allParams):\(value)")
            }
        }

        if has(CNContactPhoneNumbersKey) {
            for phone in contact.phoneNumbers { labeled("TEL", label: phone.label, value: escape(phone.value.stringValue)) }
        }
        if has(CNContactEmailAddressesKey) {
            for email in contact.emailAddresses { labeled("EMAIL", label: email.label, value: escape(email.value as String)) }
        }
        if has(CNContactPostalAddressesKey) {
            for entry in contact.postalAddresses {
                let a = entry.value
                let value = ["", "", a.street, a.city, a.state, a.postalCode, a.country].map(escape).joined(separator: ";")
                labeled("ADR", label: entry.label, value: value)
            }
        }
        if has(CNContactUrlAddressesKey) {
            for url in contact.urlAddresses { labeled("URL", label: url.label, value: singleLine(url.value as String)) }
        }
        if has(CNContactBirthdayKey), let birthday = contact.birthday, let month = birthday.month, let day = birthday.day,
           month != NSDateComponentUndefined, day != NSDateComponentUndefined {
            lines.append(dateLine("BDAY", year: birthday.year, month: month, day: day))
        }
        if has(CNContactInstantMessageAddressesKey) {
            for im in contact.instantMessageAddresses {
                let scheme = im.value.service.lowercased().filter { $0.isLetter || $0.isNumber }
                labeled(
                    "IMPP", label: im.label, params: ["X-SERVICE-TYPE=\(escape(im.value.service))"],
                    value: "\(scheme.isEmpty ? "x-apple" : scheme):\(singleLine(im.value.username))"
                )
            }
        }
        if has(CNContactSocialProfilesKey) {
            for social in contact.socialProfiles {
                let p = social.value
                let value = p.urlString.isBlank ? "x-apple:\(singleLine(p.username))" : singleLine(p.urlString)
                labeled(
                    "X-SOCIALPROFILE", label: social.label,
                    params: ["TYPE=\(escape(p.service.lowercased()))", "x-user=\(escape(p.username))"], value: value
                )
            }
        }
        if has(CNContactRelationsKey) {
            for relation in contact.contactRelations {
                let group = nextGroup()
                lines.append("\(group).X-ABRELATEDNAMES:\(escape(relation.value.name))")
                if let label = relation.label, !label.isBlank { lines.append("\(group).X-ABLabel:\(escape(label))") }
            }
        }
        if has(CNContactDatesKey) {
            for date in contact.dates {
                let value = date.value
                let group = nextGroup()
                lines.append(group + "." + dateLine(
                    "X-ABDATE", year: value.year == NSDateComponentUndefined ? nil : value.year, month: value.month, day: value.day
                ))
                if let label = date.label, !label.isBlank { lines.append("\(group).X-ABLabel:\(escape(label))") }
            }
        }
        if has(CNContactImageDataKey), let image = contact.imageData, !image.isEmpty {
            lines.append("PHOTO;ENCODING=b;TYPE=\(imageType(image)):\(image.base64EncodedString())")
        }

        lines.append("END:VCARD")
        return lines
    }

    // MARK: pieces

    /// Standard TYPE values where vCard has them; otherwise the raw CN label goes in an `X-ABLabel` group.
    private static func typeParameters(property: String, label: String?) -> (types: [String], custom: String?) {
        guard let label, !label.isBlank else { return ([], nil) }
        switch (property, label) {
        case (_, CNLabelHome): return (["HOME"], nil)
        case (_, CNLabelWork): return (["WORK"], nil)
        case ("TEL", CNLabelPhoneNumberMobile): return (["CELL"], nil)
        case ("TEL", CNLabelPhoneNumberiPhone): return (["IPHONE", "CELL"], nil)
        case ("TEL", CNLabelPhoneNumberMain): return (["MAIN"], nil)
        case ("TEL", CNLabelPhoneNumberHomeFax): return (["HOME", "FAX"], nil)
        case ("TEL", CNLabelPhoneNumberWorkFax): return (["WORK", "FAX"], nil)
        case ("TEL", CNLabelPhoneNumberPager): return (["PAGER"], nil)
        default: return ([], label)
        }
    }

    private static func dateLine(_ name: String, year: Int?, month: Int, day: Int) -> String {
        let monthDay = String(format: "%02d-%02d", month, day)
        guard let year, year > 0, year != 1604 else { return "\(name);X-APPLE-OMIT-YEAR=1604:1604-\(monthDay)" }
        return "\(name):\(String(format: "%04d", year))-\(monthDay)"
    }

    /// `vcards` with a PHOTO line added to the n-th card for each non-nil `photos[n]`, before its END:VCARD. Cards that
    /// already have a photo are left as they are.
    static func addingPhotos(_ photos: [Data?], to vcards: Data) -> Data {
        guard photos.contains(where: { $0 != nil }) else { return vcards }
        let text = String(decoding: vcards, as: UTF8.self)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var cards = text.components(separatedBy: "END:VCARD")
        for (index, photo) in photos.enumerated() where index < cards.count - 1 {
            guard let photo, !cards[index].contains("\(newline)PHOTO") else { continue }
            cards[index] += photoLine(photo, newline: newline) + newline
        }
        return Data(cards.joined(separator: "END:VCARD").utf8)
    }

    /// A vCard 3.0 PHOTO property, folded at 75 octets with a leading space on each continuation line.
    static func photoLine(_ photo: Data, newline: String = "\r\n") -> String {
        let line = "PHOTO;ENCODING=b;TYPE=\(imageType(photo)):\(photo.base64EncodedString())"
        var folded: [Substring] = []
        var rest = Substring(line)
        folded.append(rest.prefix(75))
        rest = rest.dropFirst(75)
        while !rest.isEmpty {
            folded.append(rest.prefix(74))
            rest = rest.dropFirst(74)
        }
        return folded.joined(separator: newline + " ")
    }

    static func imageType(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "GIF" }
        return "JPEG"
    }

    /// vCard text escaping: backslash, semicolon, comma and newlines.
    private static func escape(_ text: String) -> String {
        text.replacing("\\", with: "\\\\").replacing(";", with: "\\;").replacing(",", with: "\\,")
            .replacing("\r\n", with: "\\n").replacing("\n", with: "\\n").replacing("\r", with: "\\n")
    }

    private static func singleLine(_ text: String) -> String {
        text.replacing("\r\n", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
    }

    /// RFC 2425 folding: lines of at most 75 octets, continuations start with one space, never splitting a character.
    private static func fold(_ line: String) -> String {
        var out = ""
        var octets = 0
        for character in line {
            let size = String(character).utf8.count
            if octets + size > 75 {
                out += "\r\n "
                octets = 1
            }
            out.append(character)
            octets += size
        }
        return out
    }
}
