import Foundation

// MARK: - Deterministic typed-payload encoding
//
// All typed payloads encode through this single path so determinism is a property of the encoding
// seam, not a per-type patch. `.sortedKeys` makes the byte output a pure function of the value:
// without it `JSONEncoder` emits keys in unspecified (hash) order, so the same logical payload
// re-encodes to different bytes. That matters because these bytes are AES-256-GCM-sealed — a no-op
// decrypt → re-encode → re-seal of UNCHANGED data must yield identical plaintext, or it produces a
// new ciphertext and spurious change-detection / dedup churn. A fresh encoder per call keeps this
// free of shared mutable state.
func encodeTypedPayload<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}

// MARK: - Typed payload shapes (decrypted; new JSON shapes under the SAME AES-256-GCM envelope)
//
// Typed vault TV-1 (docs/typed-vault-wireframes.md §1 WF-11, §10). `items.type` already distinguishes
// these; the encrypted payload simply carries different JSON. **No crypto/store change** — this is the
// same property that lets passkeys drop in for v2. Import-clean (Foundation only). `LoginPayload` stays
// in the app target until the TV-3/Slice-10 SurfrCore extraction.

/// Payment Method (LastPass `NoteType:Credit Card`). `number` and `cvv` are **sensitive** — they live
/// only inside the encrypted payload, never in a cleartext column (reveal/copy gating is TV-2).
public struct PaymentPayload: Codable, Equatable, Sendable {
    public var nickname: String          // from the item title (cleartext metadata)
    public var cardholderName: String
    public var number: String            // SENSITIVE
    public var cardType: String
    public var expiry: String
    public var startDate: String
    public var cvv: String               // SENSITIVE
    public var notes: String
    public var rawBody: String           // the full original note body — lossless

    public init(nickname: String = "", cardholderName: String = "", number: String = "",
                cardType: String = "", expiry: String = "", startDate: String = "",
                cvv: String = "", notes: String = "", rawBody: String = "") {
        self.nickname = nickname; self.cardholderName = cardholderName; self.number = number
        self.cardType = cardType; self.expiry = expiry; self.startDate = startDate
        self.cvv = cvv; self.notes = notes; self.rawBody = rawBody
    }

    public func encoded() throws -> Data { try encodeTypedPayload(self) }
    public static func decoded(from data: Data) throws -> PaymentPayload {
        try JSONDecoder().decode(PaymentPayload.self, from: data)
    }
}

/// Address (LastPass `NoteType:Address`). **Each field is discrete** — never concatenated. `county`
/// and `stateProvince` are **separate nullable** fields (UK = county-no-state; US = the reverse); never
/// fold one into the other. All values are encrypted-payload; only the label/title is cleartext.
public struct AddressPayload: Codable, Equatable, Sendable {
    public var label: String             // from the item title (cleartext metadata)
    public var firstName: String
    public var lastName: String
    public var company: String
    public var line1: String
    public var line2: String
    public var city: String
    public var county: String?           // optional — UK
    public var stateProvince: String?    // optional — US/CA/…
    public var postalCode: String
    public var country: String
    public var phone: String
    public var phoneCountry: String?     // ISO-3 (cc3l) when the phone arrived as JSON
    public var email: String
    public var rawBody: String           // the full original note body — lossless

    public init(label: String = "", firstName: String = "", lastName: String = "", company: String = "",
                line1: String = "", line2: String = "", city: String = "", county: String? = nil,
                stateProvince: String? = nil, postalCode: String = "", country: String = "",
                phone: String = "", phoneCountry: String? = nil, email: String = "", rawBody: String = "") {
        self.label = label; self.firstName = firstName; self.lastName = lastName; self.company = company
        self.line1 = line1; self.line2 = line2; self.city = city; self.county = county
        self.stateProvince = stateProvince; self.postalCode = postalCode; self.country = country
        self.phone = phone; self.phoneCountry = phoneCountry; self.email = email; self.rawBody = rawBody
    }

    public func encoded() throws -> Data { try encodeTypedPayload(self) }
    public static func decoded(from data: Data) throws -> AddressPayload {
        try JSONDecoder().decode(AddressPayload.self, from: data)
    }
}

/// Secure Note — title (cleartext metadata) + free-text body (raw original, preserved verbatim). The
/// catch-all for everything that isn't a login / payment / address (incl. the long tail: Bank Account,
/// Passport, Wi-Fi, …). Misfiling is worse than generic.
public struct SecureNotePayload: Codable, Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String = "", body: String = "") { self.title = title; self.body = body }

    public func encoded() throws -> Data { try encodeTypedPayload(self) }
    public static func decoded(from data: Data) throws -> SecureNotePayload {
        try JSONDecoder().decode(SecureNotePayload.self, from: data)
    }
}

// MARK: - NoteType parsing (pure — the heart of TV-1)

/// The classification of a decrypted note body into one of the typed shapes.
public enum TypedNoteClassification: Equatable, Sendable {
    case payment(PaymentPayload)
    case address(AddressPayload)
    case secureNote(SecureNotePayload)
}

/// Classifies and extracts a LastPass secure-note body (the decrypted note text) into a typed payload.
/// Pure + headless; unit-tested against the real export samples. **Lossless** — the full body is always
/// retained in `rawBody`, so an unmapped or unexpected label is never dropped.
public enum TypedNoteParser {

    /// `NoteType:` is always line 1, an exact first-line prefix. Missing / misspelled / absent marker →
    /// `secureNote` (never misfile). For payment/address, labelled lines are mapped to discrete fields
    /// while the raw body is preserved.
    public static func classify(title: String, body: String) -> TypedNoteClassification {
        let lines = body.components(separatedBy: "\n")
        let firstLine = (lines.first ?? "").trimmingCharacters(in: .whitespaces)

        guard firstLine.lowercased().hasPrefix("notetype:") else {
            return .secureNote(SecureNotePayload(title: title, body: body))
        }
        let noteType = String(firstLine.dropFirst("notetype:".count))
            .trimmingCharacters(in: .whitespaces).lowercased()

        // Build a label→value map from the remaining lines (split on the FIRST colon, so a JSON phone
        // value's internal colons stay in the value). Last duplicate wins; rawBody keeps everything.
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { fields[label] = value }
        }

        switch noteType {
        case "credit card": return .payment(parsePayment(title: title, body: body, fields: fields))
        case "address":     return .address(parseAddress(title: title, body: body, fields: fields))
        default:            return .secureNote(SecureNotePayload(title: title, body: body))
        }
    }

    // MARK: Field mapping (real LastPass labels)

    private static func parsePayment(title: String, body: String, fields: [String: String]) -> PaymentPayload {
        // Normalize LastPass month NAMES / variants → canonical MM/YYYY (e.g. "June, 2023" → "06/2023");
        // an unparseable value is kept raw so it's flagged (not lost).
        func canonOrRaw(_ raw: String) -> String {
            let canon = CardValidation.canonicalMonthYear(raw)
            return canon.isEmpty ? raw : canon
        }
        return PaymentPayload(
            nickname:       title,
            cardholderName: fields["name on card"] ?? "",
            number:         fields["number"] ?? "",
            cardType:       fields["type"] ?? "",
            expiry:         canonOrRaw(fields["expiration date"] ?? ""),
            startDate:      canonOrRaw(fields["start date"] ?? ""),
            cvv:            fields["security code"] ?? "",
            notes:          fields["notes"] ?? "",
            rawBody:        body
        )
    }

    private static func parseAddress(title: String, body: String, fields: [String: String]) -> AddressPayload {
        // "Address 3" is rare; fold it onto line2 (separated) so nothing is lost — the full body also
        // survives in rawBody. "Title" (honorific) is intentionally NOT a structured field.
        var line2 = fields["address 2"] ?? ""
        if let line3 = fields["address 3"], !line3.isEmpty {
            line2 = line2.isEmpty ? line3 : line2 + ", " + line3
        }
        let (phone, phoneCountry) = parsePhone(fields["phone"] ?? fields["mobile phone"] ?? "")
        return AddressPayload(
            label:         title,
            firstName:     fields["first name"] ?? "",
            lastName:      fields["last name"] ?? "",
            company:       fields["company"] ?? "",
            line1:         fields["address 1"] ?? "",
            line2:         line2,
            city:          fields["city / town"] ?? "",
            county:        nonEmpty(fields["county"]),         // separate nullable (UK)
            stateProvince: nonEmpty(fields["state"]),          // separate nullable (US/…)
            postalCode:    fields["zip / postal code"] ?? "",
            country:       fields["country"] ?? "",
            phone:         phone,
            phoneCountry:  phoneCountry,
            email:         fields["email address"] ?? "",
            rawBody:       body
        )
    }

    /// LastPass phone fields arrive as JSON (`{"num":"+44…","cc3l":"GBR","ext":""}`). Parse leniently:
    /// - JSON that **parses successfully** → use `num` (+ `cc3l`); an **empty `num` is an empty phone**
    ///   (`("", nil)`), NOT the raw JSON — an all-empty object like `{"num":"","cc3l":""}` is no data,
    ///   not a parse failure.
    /// - JSON that **fails to parse** (malformed) or any non-JSON text → keep the raw string (could be a
    ///   plain number). Never drop a real value.
    public static func parsePhone(_ raw: String) -> (number: String, country: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let num = (obj["num"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !num.isEmpty else { return ("", nil) }     // empty JSON object → empty phone
            let cc = (obj["cc3l"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (num, cc)
        }
        return (raw, nil)   // not JSON, or malformed JSON → keep raw verbatim
    }

    /// Map an absent OR blank field to `nil` — so a UK address (no `State:` line, or a blank one) leaves
    /// `stateProvince` nil, and vice-versa.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
