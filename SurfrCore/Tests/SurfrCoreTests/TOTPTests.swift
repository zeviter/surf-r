import XCTest
@testable import SurfrCore

final class TOTPTests: XCTestCase {

    // RFC 6238 Appendix B test vectors (8 digits, period 30).
    func test_rfc6238_vectors() {
        let sha1 = TOTP(secret: Data("12345678901234567890".utf8), algorithm: .sha1, digits: 8)
        let cases: [(TimeInterval, String)] = [
            (59, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"),
            (1234567890, "89005924"), (2000000000, "69279037"),
        ]
        for (t, expected) in cases {
            XCTAssertEqual(sha1.code(at: Date(timeIntervalSince1970: t)), expected, "SHA1 @ \(t)")
        }
        let sha256 = TOTP(secret: Data("12345678901234567890123456789012".utf8), algorithm: .sha256, digits: 8)
        XCTAssertEqual(sha256.code(at: Date(timeIntervalSince1970: 59)), "46119246")

        let sha512 = TOTP(secret: Data("1234567890123456789012345678901234567890123456789012345678901234".utf8),
                          algorithm: .sha512, digits: 8)
        XCTAssertEqual(sha512.code(at: Date(timeIntervalSince1970: 59)), "90693936")
    }

    func test_secondsRemaining() {
        let t = TOTP(secret: Data("x".utf8), period: 30)
        XCTAssertEqual(t.secondsRemaining(at: Date(timeIntervalSince1970: 0)), 30)
        XCTAssertEqual(t.secondsRemaining(at: Date(timeIntervalSince1970: 29)), 1)
    }

    func test_base32_roundTripAndKnown() {
        XCTAssertEqual(Base32.encode(Data("Hello!".utf8 + [0xde, 0xad, 0xbe, 0xef])), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(Base32.decode("jbswy3dpehpk3pxp"), Data("Hello!".utf8 + [0xde, 0xad, 0xbe, 0xef]))
        XCTAssertNil(Base32.decode("0189!"))   // invalid alphabet
    }

    func test_otpauthURI_parse() {
        let uri = "otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA256&digits=8&period=60"
        let t = TOTP(otpauthURI: uri)
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.issuer, "Example")
        XCTAssertEqual(t?.account, "alice@google.com")
        XCTAssertEqual(t?.algorithm, .sha256)
        XCTAssertEqual(t?.digits, 8)
        XCTAssertEqual(t?.period, 60)
        XCTAssertNil(TOTP(otpauthURI: "otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP"))   // not TOTP
        XCTAssertNil(TOTP(otpauthURI: "otpauth://totp/x?secret=!!!"))                // bad secret
    }

    // MARK: - Migration

    func test_migration_knownPublicVector() throws {
        let uri = "otpauth-migration://offline?data=CjEKCkhlbGxvIb6tvQ8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZSABKAEwAhABGAEgAA%3D%3D"
        let entries = try OTPMigration.decode(uri.removingPercentEncoding ?? uri)
        // Real GAuth field layout: issuer/account/alg/digits extracted correctly. (Exact-secret
        // fidelity is proven by the hand-encoded round-trip below.)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].totp.secret.isEmpty)
        XCTAssertEqual(entries[0].issuer, "Example")
        XCTAssertTrue(entries[0].account.contains("alice@google.com"))
        XCTAssertEqual(entries[0].totp.algorithm, .sha1)
        XCTAssertEqual(entries[0].totp.digits, 6)
    }

    func test_migration_handEncodedRoundTrip() throws {
        let uri = makeMigration([
            (secret: Array("12345678901234567890".utf8), name: "alice", issuer: "GitHub", alg: 1, digits: 1, type: 2),
            (secret: Array("Hello!".utf8 + [0xde, 0xad, 0xbe, 0xef]), name: "bob", issuer: "AWS", alg: 2, digits: 2, type: 2),
            (secret: Array("nope".utf8), name: "hotp", issuer: "X", alg: 1, digits: 1, type: 1),   // HOTP → skipped
        ])
        let entries = try OTPMigration.decode(uri)
        XCTAssertEqual(entries.count, 2, "HOTP entry skipped")
        XCTAssertEqual(entries[0].issuer, "GitHub")
        XCTAssertEqual(entries[0].totp.algorithm, .sha1)
        XCTAssertEqual(entries[0].totp.digits, 6)
        XCTAssertEqual(entries[1].issuer, "AWS")
        XCTAssertEqual(entries[1].totp.algorithm, .sha256)
        XCTAssertEqual(entries[1].totp.digits, 8)
        // The first entry's code matches a direct TOTP from the same secret.
        let direct = TOTP(secret: Data("12345678901234567890".utf8), algorithm: .sha1, digits: 6)
        XCTAssertEqual(entries[0].totp.code(at: Date(timeIntervalSince1970: 59)),
                       direct.code(at: Date(timeIntervalSince1970: 59)))
    }

    func test_migration_rejectsNonMigrationURI() {
        XCTAssertThrowsError(try OTPMigration.decode("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"))
    }

    // Minimal protobuf encoder for the round-trip test.
    private func makeMigration(_ params: [(secret: [UInt8], name: String, issuer: String, alg: Int, digits: Int, type: Int)]) -> String {
        func varint(_ v: Int) -> [UInt8] {
            var value = UInt64(v); var out = [UInt8]()
            repeat { var b = UInt8(value & 0x7f); value >>= 7; if value != 0 { b |= 0x80 }; out.append(b) } while value != 0
            return out
        }
        func lenDelim(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { [UInt8(field << 3 | 2)] + varint(bytes.count) + bytes }
        func varField(_ field: Int, _ value: Int) -> [UInt8] { [UInt8(field << 3 | 0)] + varint(value) }
        var payload = [UInt8]()
        for p in params {
            let msg = lenDelim(1, p.secret) + lenDelim(2, Array(p.name.utf8)) + lenDelim(3, Array(p.issuer.utf8))
                + varField(4, p.alg) + varField(5, p.digits) + varField(6, p.type)
            payload += lenDelim(1, msg)
        }
        var comps = URLComponents()
        comps.scheme = "otpauth-migration"; comps.host = "offline"
        comps.queryItems = [URLQueryItem(name: "data", value: Data(payload).base64EncodedString())]
        return comps.string!
    }
}
