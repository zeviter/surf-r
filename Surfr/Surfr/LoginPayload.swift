import Foundation

/// The **decrypted** shape of a login item (vault-spec §6) — the canonical encrypted-blob schema both
/// the app and the future AutoFill extension must agree on.
///
/// Deliberately **import-clean** (Foundation / `Codable` only, no UI types), so the Slice 10 move into
/// `SurfrCore` (shared with the extension) is a relocation, not a rewrite. Only ciphertext of this
/// blob is ever persisted; an instance exists in memory only while one item's detail is open.
struct LoginPayload: Codable, Equatable {
    var username: String
    var password: String
    var notes: String
    var totp: String?               // otpauth:// URI — populated in Slice 7
    var urls: [String]
    var passwordChangedAt: Date?
    var custom: [String: String]

    init(username: String = "",
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

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decoded(from data: Data) throws -> LoginPayload {
        try JSONDecoder().decode(LoginPayload.self, from: data)
    }
}
