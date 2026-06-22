import Foundation

/// Decoder for Google Authenticator's `otpauth-migration://offline?data=…` export (the "Export
/// accounts" QR). `data` is base64 of a protobuf `MigrationPayload`; we hand-parse the (tiny, fixed)
/// wire format — no protobuf dependency — and emit standard `TOTP`s.
public enum OTPMigration {
    public struct Entry: Equatable, Sendable {
        public let totp: TOTP
        public var otpauthURI: String { totp.otpauthURI() }
        public var issuer: String { totp.issuer }
        public var account: String { totp.account }
    }

    public enum Failure: Error, Equatable { case notMigrationURI, badData, noEntries }

    public static func decode(_ uri: String) throws -> [Entry] {
        guard let comps = URLComponents(string: uri), comps.scheme?.lowercased() == "otpauth-migration" else {
            throw Failure.notMigrationURI
        }
        guard let dataValue = comps.queryItems?.first(where: { $0.name == "data" })?.value,
              let payload = Data(base64Encoded: dataValue) else { throw Failure.badData }

        var reader = ProtoReader(Array(payload))
        var entries: [Entry] = []
        while !reader.atEnd {
            guard let (field, wire) = reader.tag() else { break }
            if field == 1, wire == 2 {                       // repeated OtpParameters otp_parameters = 1
                guard let message = reader.lengthDelimited() else { break }
                if let entry = parseParameters(message) { entries.append(entry) }
            } else if !reader.skip(wire) {
                break
            }
        }
        guard !entries.isEmpty else { throw Failure.noEntries }
        return entries
    }

    /// OtpParameters: secret=1(bytes), name=2(str), issuer=3(str), algorithm=4(enum), digits=5(enum),
    /// type=6(enum), counter=7(varint). Only TOTP (type 2) with a usable secret is emitted.
    private static func parseParameters(_ bytes: [UInt8]) -> Entry? {
        var r = ProtoReader(bytes)
        var secret = Data(), name = "", issuer = ""
        var algRaw: UInt64 = 1, digitsRaw: UInt64 = 1, type: UInt64 = 2
        while !r.atEnd {
            guard let (field, wire) = r.tag() else { break }
            switch (field, wire) {
            case (1, 2): secret = Data(r.lengthDelimited() ?? [])
            case (2, 2): name = String(decoding: r.lengthDelimited() ?? [], as: UTF8.self)
            case (3, 2): issuer = String(decoding: r.lengthDelimited() ?? [], as: UTF8.self)
            case (4, 0): algRaw = r.varint() ?? 1
            case (5, 0): digitsRaw = r.varint() ?? 1
            case (6, 0): type = r.varint() ?? 2
            default: if !r.skip(wire) { return nil }
            }
        }
        guard type == 2, !secret.isEmpty else { return nil }   // TOTP only; HOTP/empty skipped
        let algorithm: TOTP.Algorithm
        switch algRaw {
        case 2: algorithm = .sha256
        case 3: algorithm = .sha512
        case 4: return nil                                     // MD5 unsupported — skip, don't mis-map
        default: algorithm = .sha1                             // 0 unspecified / 1 SHA1
        }
        let digits = (digitsRaw == 2) ? 8 : 6
        return Entry(totp: TOTP(secret: secret, algorithm: algorithm, digits: digits, period: 30,
                                issuer: issuer, account: name))
    }
}

/// Minimal protobuf wire reader (varint, length-delimited, skip).
private struct ProtoReader {
    let bytes: [UInt8]
    var i = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var atEnd: Bool { i >= bytes.count }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func tag() -> (field: Int, wire: Int)? {
        guard let t = varint() else { return nil }
        return (Int(t >> 3), Int(t & 0x7))
    }

    mutating func lengthDelimited() -> [UInt8]? {
        guard let len = varint(), i + Int(len) <= bytes.count else { return nil }
        defer { i += Int(len) }
        return Array(bytes[i..<i + Int(len)])
    }

    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 2: return lengthDelimited() != nil
        case 5: i += 4; return i <= bytes.count
        case 1: i += 8; return i <= bytes.count
        default: return false
        }
    }
}
