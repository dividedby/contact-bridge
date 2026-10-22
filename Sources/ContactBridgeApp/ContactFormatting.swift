import ContactBridgeCore
import SwiftUI

extension MatchFlag {
    var title: String {
        switch self {
        case .sharedPhoneDifferentNames: "Shared phone, different names"
        case .sharedEmailDifferentNames: "Shared email, different names"
        case .conflictingContactInfo: "Same name, different phone/email"
        case .sharedIdentifierUnnamedRecord: "Shares a phone/email with a record that has no name"
        case .memberNameConflict: "Two members have different names"
        case .nameSpellingVariant: "Names differ by a spelling variant"
        }
    }
}

extension ConfidenceLevel {
    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var color: Color {
        switch self {
        case .low: .orange
        case .medium: .yellow
        case .high: .green
        }
    }
}

/// "High 92%" in a small capsule.
struct ConfidenceBadge: View {
    var confidence: Double?

    var body: some View {
        if let confidence {
            let level = ConfidenceLevel(confidence: confidence)
            Text("\(level.title) \(Int((confidence * 100).rounded()))%")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(level.color.opacity(0.25), in: Capsule())
        } else {
            Text("No link").font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.orange.opacity(0.25), in: Capsule())
        }
    }
}

/// Conflict flags are warnings; the others are information.
struct FlagLabel: View {
    var flag: MatchFlag

    var body: some View {
        if flag.isConflict {
            Label(flag.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Label(flag.title, systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }
}

enum ContactText {
    static func phonesOrEmails(_ values: [Labeled<String>]) -> String {
        values.filter { !$0.value.isBlank }.map { entry in
            if let label = entry.label, !label.isBlank { "\(entry.value) (\(label))" } else { entry.value }
        }.joined(separator: "\n")
    }

    static func addresses(_ values: [Labeled<PostalAddress>]) -> String {
        values.filter { !$0.value.isEmpty }.map { entry in
            let a = entry.value
            let line = [a.street, a.city, a.state, a.postalCode, a.country].filter { !$0.isBlank }.joined(separator: ", ")
            if let label = entry.label, !label.isBlank { return "\(line) (\(label))" }
            return line
        }.joined(separator: "\n")
    }

    static func birthday(_ components: DateComponents?) -> String {
        guard let components, let month = components.month, let day = components.day else { return "" }
        let year = components.year.map { String(format: "%04d-", $0) } ?? "--"
        return year + String(format: "%02d-%02d", month, day)
    }

    /// "1 contact", "2 contacts".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// What tells two same-named contacts apart: first email and first phone (or the organization), else a plain note.
    static func distinguishing(_ record: ContactRecord) -> String {
        let parts = [record.emails.first?.value, record.phones.first?.value].compactMap { $0 }.filter { !$0.isBlank }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return record.organization.isBlank ? "no email or phone" : record.organization
    }

    /// One-line summary for lists: first email, else first phone.
    static func contactLine(_ record: ContactRecord) -> String {
        let parts = [record.emails.first?.value, record.phones.first?.value, record.organization.isBlank ? nil : record.organization]
        return parts.compactMap { $0 }.filter { !$0.isBlank }.joined(separator: " · ")
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
