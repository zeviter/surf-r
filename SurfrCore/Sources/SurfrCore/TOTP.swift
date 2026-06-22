import Foundation
import CryptoKit

/// RFC 4648 Base32 (no padding) — the encoding `otpauth://` uses for the shared secret.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ string: String) -> Data? {
        let clean = string.uppercased().filter { $0 != "=" && $0 != " " && $0 != "-" }
        var lookup: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = i }
        var value = 0, bits = 0
        var out = [UInt8]()
        for ch in clean {
            guard let v = lookup[ch] else { return nil }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        return Data(out)
    }

    public static func encode(_ data: Data) -> String {
        var value = 0, bits = 0
        var out = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 { out.append(alphabet[(value >> (bits - 5)) & 0x1f]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 0x1f]) }
        return out
    }
}

/// A time-based one-time password (RFC 6238 / 4226). Pure + headless; the secret is raw bytes.
public struct TOTP: Equatable, Sendable {
    public enum Algorithm: String, Sendable, Equatable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    public var secret: Data
    public var algorithm: Algorithm
    public var digits: Int
    public var period: Int
    public var issuer: String
    public var account: String

    public init(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30,
                issuer: String = "", account: String = "") {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = max(6, min(8, digits))
        self.period = max(1, period)
        self.issuer = issuer
        self.account = account
    }

    /// Current code at `date`.
    public func code(at date: Date = Date()) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period)
        return Self.hotp(secret: secret, counter: counter, algorithm: algorithm, digits: digits)
    }

    /// Seconds left in the current window (for the countdown ring).
    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(UInt64(max(0, date.timeIntervalSince1970)) % UInt64(period))
    }

    static func hotp(secret: Data, counter: UInt64, algorithm: Algorithm, digits: Int) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: Data
        switch algorithm {
        case .sha1:   mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulo: UInt32 = 1
        for _ in 0..<digits { modulo &*= 10 }
        return String(format: "%0\(digits)u", binary % modulo)
    }

    /// Parse a standard `otpauth://totp/LABEL?secret=…` URI. Returns nil for non-TOTP / bad secret.
    public init?(otpauthURI: String) {
        guard let comps = URLComponents(string: otpauthURI),
              comps.scheme?.lowercased() == "otpauth",
              comps.host?.lowercased() == "totp" else { return nil }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") })
        guard let secretB32 = items["secret"], let secret = Base32.decode(secretB32), !secret.isEmpty else { return nil }

        let label = comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path
        var issuer = items["issuer"] ?? ""
        var account = label
        if label.contains(":") {                 // "Issuer:Account"
            let parts = label.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if issuer.isEmpty { issuer = parts.first ?? "" }
            account = parts.count > 1 ? parts[1] : label
        }
        let alg = Algorithm(rawValue: (items["algorithm"] ?? "SHA1").uppercased()) ?? .sha1
        let digits = Int(items["digits"] ?? "") ?? 6
        let period = Int(items["period"] ?? "") ?? 30
        self.init(secret: secret, algorithm: alg, digits: digits, period: period, issuer: issuer, account: account)
    }

    /// Build a canonical `otpauth://` URI (used by the migration decoder).
    public func otpauthURI() -> String {
        let label = issuer.isEmpty ? account : "\(issuer):\(account)"
        var comps = URLComponents()
        comps.scheme = "otpauth"; comps.host = "totp"
        comps.path = "/" + label
        var q = [URLQueryItem(name: "secret", value: Base32.encode(secret))]
        if !issuer.isEmpty { q.append(URLQueryItem(name: "issuer", value: issuer)) }
        q.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue))
        q.append(URLQueryItem(name: "digits", value: String(digits)))
        q.append(URLQueryItem(name: "period", value: String(period)))
        comps.queryItems = q
        return comps.string ?? ""
    }
}
