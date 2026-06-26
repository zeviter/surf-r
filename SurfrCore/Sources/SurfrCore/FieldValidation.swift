import Foundation

/// A **soft** field-validation result (TV-2-VAL). Validation only GUIDES + WARNS — it never throws,
/// never gates a save. The UI maps `.suspect` to a subtle **amber** highlight + a short hint; an empty
/// field is always `.ok` (we never nag empties or trap existing malformed imports).
public enum FieldCheck: Equatable, Sendable {
    case ok
    case suspect(String)            // reason, e.g. "doesn't look like a valid card number"

    public var isSuspect: Bool { if case .suspect = self { return true } else { return false } }
    public var reason: String? { if case .suspect(let r) = self { return r } else { return nil } }
}

/// Pure, soft payment-field validators. None gate; each returns `.ok` for empty input (never nag).
public enum CardValidation {

    /// Luhn checksum over the digits of a PAN.
    public static func luhn(_ number: String) -> Bool {
        let d = number.compactMap(\.wholeNumberValue)
        guard d.count >= 2 else { return false }
        var sum = 0
        for (i, digit) in d.reversed().enumerated() {
            if i % 2 == 1 { let doubled = digit * 2; sum += doubled > 9 ? doubled - 9 : doubled }
            else { sum += digit }
        }
        return sum % 10 == 0
    }

    /// Card number — suspect if it isn't 12–19 digits or fails Luhn. Empty ⇒ ok.
    public static func cardNumber(_ s: String) -> FieldCheck {
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return .ok }
        let d = CardDetection.digits(s)
        guard (12...19).contains(d.count) else { return .suspect("doesn’t look like a valid card number") }
        return luhn(d) ? .ok : .suspect("doesn’t look like a valid card number")
    }

    /// CVV — suspect if it isn't 3–4 digits (or contains non-digits). Empty ⇒ ok.
    public static func cvv(_ s: String) -> FieldCheck {
        let raw = s.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return .ok }
        let d = CardDetection.digits(s)
        return (d.count == raw.count && (3...4).contains(d.count)) ? .ok : .suspect("CVV is usually 3–4 digits")
    }

    /// Expiry / valid-from — suspect if it can't be read as a month + year. Empty ⇒ ok. (Editor uses
    /// month/year pickers, so this mainly flags already-imported junk like "ofdsfds".)
    public static func expiry(_ s: String) -> FieldCheck {
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return .ok }
        guard let my = parseMonthYear(s), (1...12).contains(my.month) else {
            return .suspect("doesn’t look like a valid date")
        }
        return .ok
    }

    /// THE canonical month/year representation — zero-padded month + 4-digit year (`MM/YYYY`). The single
    /// stored + displayed format for expiry AND valid-from. Returns `""` if the input can't be parsed
    /// (callers keep the raw value so nothing is lost — it just stays flagged).
    public static func canonicalMonthYear(_ s: String) -> String {
        guard let my = parseMonthYear(s), (1...12).contains(my.month) else { return "" }
        return String(format: "%02d/%04d", my.month, my.year)
    }

    /// Lenient parse of a stored expiry/valid-from string → (month, year). Handles `MM/YYYY`, `MM/YY`,
    /// `M/YY`, month names (`June, 2028`), and `YYYY/MM`. Returns nil for junk. Two-digit years → 2000+.
    public static func parseMonthYear(_ s: String) -> (month: Int, year: Int)? {
        let lower = s.lowercased()
        let names = ["january","february","march","april","may","june",
                     "july","august","september","october","november","december"]
        var month: Int?
        for (i, name) in names.enumerated() where lower.contains(name) || lower.contains(String(name.prefix(3))) {
            month = i + 1; break
        }
        let groups = s.split { !$0.isNumber }.compactMap { Int($0) }
        var year: Int?
        if month != nil {
            year = groups.first { $0 >= 1900 || (0...99).contains($0) }
        } else if groups.count >= 2 {
            let a = groups[0], b = groups[1]
            if (1...12).contains(a) { month = a; year = b }
            else if (1...12).contains(b) { month = b; year = a }
        }
        guard let m = month, var y = year else { return nil }
        if y < 100 { y += 2000 }
        return (m, y)
    }
}
