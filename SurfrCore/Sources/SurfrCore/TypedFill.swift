import Foundation

/// Pure mappers from a decrypted typed payload to the `{token: value}` dictionary the in-browser fill JS
/// writes into a detected card/address form (TV-3a). Headless + import-clean, so the same mapping serves
/// the coming AutoFill extension. **No sensitive value reaches here until the caller has already decrypted
/// the user-chosen item and passed the auth gate** — these are just shape transforms, never a decryption.

public enum CardFill {
    /// Card values keyed for `__surfrFillCard`. `number` is digits-only (forms validate the raw PAN); the
    /// expiry is offered three ways (combined `MM/YY` + split `MM`/`YYYY`) so it maps whether the form has
    /// one field or two. `cvv`/`name` are omitted when empty — never invented (the JS also gates on the
    /// field existing).
    public static func values(from p: PaymentPayload) -> [String: String] {
        var v: [String: String] = [:]
        let digits = p.number.filter(\.isNumber)
        if !digits.isEmpty { v["number"] = digits }
        if !p.cardholderName.isEmpty { v["name"] = p.cardholderName }
        if !p.cvv.isEmpty { v["cvv"] = p.cvv }
        if let my = CardValidation.parseMonthYear(p.expiry) {
            v["expMonth"] = String(format: "%02d", my.month)
            v["expYear"] = String(format: "%04d", my.year)
            v["exp"] = String(format: "%02d/%02d", my.month, my.year % 100)   // common combined MM/YY
        }
        return v
    }
}

public enum AddressFill {
    /// Address values keyed for `__surfrFillAddress`. Empty fields are omitted (the JS skips a missing
    /// value anyway). `name` is first+last joined. **County is intentionally not mapped** — it has no
    /// standard autocomplete token, so it's never web-filled (in-vault only), per the TV-3 build rules.
    public static func values(from a: AddressPayload) -> [String: String] {
        var v: [String: String] = [:]
        func add(_ key: String, _ value: String) { if !value.isEmpty { v[key] = value } }
        add("line1", a.line1)
        add("line2", a.line2)
        add("city", a.city)
        add("state", a.stateProvince ?? "")
        add("postal", a.postalCode)
        add("country", a.country)
        add("name", [a.firstName, a.lastName].filter { !$0.isEmpty }.joined(separator: " "))
        add("tel", a.phone)
        add("email", a.email)
        return v
    }
}
