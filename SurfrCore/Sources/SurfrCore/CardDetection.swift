import Foundation

/// Payment-card networks, detected **locally** from the IIN/BIN prefix (TV-2b). The detected network is
/// the source of truth for the card glyph + the stored `card_network` cleartext hint; the LastPass
/// `cardType` string (a product name like "Premier Debit") is **not** a network and never drives the glyph.
public enum CardNetwork: String, Sendable, CaseIterable, Equatable {
    case visa, mastercard, amex, discover, diners, jcb, unionpay, unknown

    public var displayName: String {
        switch self {
        case .visa:       return "Visa"
        case .mastercard: return "Mastercard"
        case .amex:       return "American Express"
        case .discover:   return "Discover"
        case .diners:     return "Diners Club"
        case .jcb:        return "JCB"
        case .unionpay:   return "UnionPay"
        case .unknown:    return "Card"
        }
    }

    /// Round-trips a stored `card_network` hint string back to the enum (`.unknown` if missing/garbled).
    public static func from(hint: String?) -> CardNetwork {
        guard let hint else { return .unknown }
        return CardNetwork(rawValue: hint) ?? .unknown
    }
}

/// Pure, no-network card helpers (TV-2b). Prefix math only.
public enum CardDetection {

    /// Digits-only form of a possibly-formatted PAN.
    public static func digits(_ number: String) -> String { number.filter(\.isNumber) }

    /// Last 4 digits of the PAN — the standard displayed identifier (not PCI-sensitive). `""` if none.
    public static func last4(_ number: String) -> String {
        let d = digits(number)
        return d.count >= 4 ? String(d.suffix(4)) : d
    }

    /// Digits of the PAN grouped into blocks (default 4) for display/entry, e.g. `4111 1111 1111 1111`.
    public static func grouped(_ number: String, size: Int = 4) -> String {
        let d = digits(number)
        guard size > 0, !d.isEmpty else { return "" }
        return stride(from: 0, to: d.count, by: size).map { i -> String in
            let start = d.index(d.startIndex, offsetBy: i)
            let end = d.index(start, offsetBy: size, limitedBy: d.endIndex) ?? d.endIndex
            return String(d[start..<end])
        }.joined(separator: " ")
    }

    /// Detect the network from the IIN prefix. Pure; **no network lookup**; `.unknown` if no match.
    public static func network(_ number: String) -> CardNetwork {
        let d = digits(number)
        guard d.count >= 2 else { return .unknown }
        func pre(_ n: Int) -> Int? { d.count >= n ? Int(d.prefix(n)) : nil }

        if let p2 = pre(2), p2 == 34 || p2 == 37 { return .amex }
        if let p2 = pre(2), [36, 38, 39].contains(p2) { return .diners }
        if let p3 = pre(3), (300...305).contains(p3) { return .diners }
        if let p4 = pre(4), (3528...3589).contains(p4) { return .jcb }
        if d.hasPrefix("4") { return .visa }
        if let p2 = pre(2), (51...55).contains(p2) { return .mastercard }
        if let p4 = pre(4), (2221...2720).contains(p4) { return .mastercard }
        if let p4 = pre(4), p4 == 6011 { return .discover }
        if let p2 = pre(2), p2 == 65 { return .discover }
        if let p3 = pre(3), (644...649).contains(p3) { return .discover }
        if let p6 = pre(6), (622126...622925).contains(p6) { return .discover }
        if let p2 = pre(2), p2 == 62 { return .unionpay }
        return .unknown
    }
}
