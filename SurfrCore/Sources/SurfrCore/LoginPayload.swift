import Foundation

/// The **decrypted** shape of a login item (vault-spec §6) — the canonical encrypted-blob schema both
/// the app and the AutoFill extension must agree on. Relocated into `SurfrCore` in Slice 10-1 so the
/// extension and the in-browser fill path share **one** copy.
///
/// Import-clean (Foundation / `Codable` only, no UI types). Only ciphertext of this blob is ever
/// persisted; an instance exists in memory only while one item's detail is open.
public struct LoginPayload: Codable, Equatable, Sendable {
    public var username: String
    public var password: String
    public var notes: String
    public var totp: String?               // otpauth:// URI — populated in Slice 7
    public var urls: [String]
    public var passwordChangedAt: Date?
    public var custom: [String: String]

    public init(username: String = "",
                password: String = "",
                notes: String = "",
                totp: String? = nil,
                urls: [String] = [],
                passwordChangedAt: Date? = nil,
                custom: [String: String] = [:]) {
        self.username = username
        self.password = password
        self.notes = notes
        self.totp = totp
        self.urls = urls
        self.passwordChangedAt = passwordChangedAt
        self.custom = custom
    }

    /// Deterministic encoding (Slice 10-1): routed through the shared `.sortedKeys` encoder, matching the
    /// typed payloads — so a no-op decrypt → re-encode → re-seal of unchanged data yields identical
    /// plaintext (no spurious AES-GCM ciphertext churn). The `custom` dictionary's key order is now stable
    /// too. Decoding is content-based, so existing stored logins (encoded with the old, unsorted bare
    /// encoder) still decrypt unchanged — only newly-written bytes differ. Closes the pinned backlog note.
    public func encoded() throws -> Data { try encodeTypedPayload(self) }
    public static func decoded(from data: Data) throws -> LoginPayload {
        try JSONDecoder().decode(LoginPayload.self, from: data)
    }
}
