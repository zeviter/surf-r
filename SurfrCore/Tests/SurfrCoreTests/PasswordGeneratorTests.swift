import XCTest
@testable import SurfrCore

final class PasswordGeneratorTests: XCTestCase {

    // MARK: Random characters

    func test_length_isHonored() {
        for n in [8, 16, 20, 32, 64] {
            XCTAssertEqual(PasswordGenerator.random(.init(length: n)).count, n)
        }
    }

    func test_eachSelectedClassAppearsAtLeastOnce() {
        let upper = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        let digits = CharacterSet(charactersIn: "0123456789")
        let symbols = CharacterSet(charactersIn: PasswordGenerator.symbols)
        // Minimum length where each class still must appear; many runs to catch probabilistic gaps.
        for _ in 0..<500 {
            let pw = PasswordGenerator.random(.init(length: 8, upper: true, lower: true, digits: true, symbols: true))
            for (name, set) in [("upper", upper), ("lower", lower), ("digit", digits), ("symbol", symbols)] {
                XCTAssertTrue(pw.unicodeScalars.contains { set.contains($0) }, "missing \(name) in \(pw)")
            }
        }
    }

    func test_onlySelectedClasses() {
        for _ in 0..<200 {
            let pw = PasswordGenerator.random(.init(length: 24, upper: false, lower: true, digits: true, symbols: false))
            XCTAssertTrue(pw.allSatisfy { $0.isLowercase || $0.isNumber }, "unexpected class in \(pw)")
        }
    }

    func test_excludeAmbiguous_neverEmitsAmbiguousSet() {
        for _ in 0..<500 {
            let pw = PasswordGenerator.random(.init(length: 40, excludeAmbiguous: true))
            XCTAssertFalse(pw.contains { PasswordGenerator.ambiguous.contains($0) }, "ambiguous char in \(pw)")
        }
    }

    func test_deselectAll_fallsBackSafely() {
        let pw = PasswordGenerator.random(.init(length: 16, upper: false, lower: false, digits: false, symbols: false))
        XCTAssertEqual(pw.count, 16)
        XCTAssertTrue(pw.allSatisfy { $0.isLowercase })   // safety net
    }

    func test_uniqueAcrossRuns() {
        let set = Set((0..<1000).map { _ in PasswordGenerator.random(.init(length: 20)) })
        XCTAssertEqual(set.count, 1000, "generated passwords must not collide")
    }

    // MARK: Entropy math

    func test_entropy_random() {
        // Full set: 26 upper + 26 lower + 10 digits + 24 symbols = 86 chars.
        let o = PasswordGenerator.RandomOptions(length: 20)
        XCTAssertEqual(PasswordGenerator.poolSize(for: o), 86)
        let bits = PasswordGenerator.entropyBits(for: o)
        XCTAssertEqual(bits, 20 * log2(86), accuracy: 0.001)
        XCTAssertEqual(PasswordGenerator.strength(bits: bits), .excellent)
        // lower-only, len 8: 8 × log2(26) ≈ 37.6 → Weak
        XCTAssertEqual(PasswordGenerator.strength(bits: PasswordGenerator.entropyBits(
            for: .init(length: 8, upper: false, lower: true, digits: false, symbols: false))), .weak)
    }

    func test_entropy_passphrase() {
        XCTAssertEqual(PasswordGenerator.passphraseEntropyBits(wordCount: 6, listSize: 7776),
                       6 * log2(7776), accuracy: 0.001)
        XCTAssertGreaterThan(PasswordGenerator.passphraseEntropyBits(wordCount: 6, listSize: 7776), 77)   // master floor
    }

    // MARK: Unbiased index distribution

    func test_indexDistribution_isUniform() {
        let n = 17                     // non-power-of-two → exposes modulo bias if present
        let samples = 170_000
        var counts = [Int](repeating: 0, count: n)
        for _ in 0..<samples { counts[CSPRNG.index(n)] += 1 }
        let expected = Double(samples) / Double(n)
        // Chi-square goodness-of-fit; df=16, 0.001 critical ≈ 39.25. A biased modulo would blow past it.
        let chi = counts.reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
        XCTAssertLessThan(chi, 39.25, "index distribution looks biased (chi^2=\(chi))")
    }

    // MARK: Diceware

    func test_wordlist_loadsExactly7776() {
        XCTAssertEqual(EFFWordList.words.count, 7776)
        XCTAssertTrue(EFFWordList.words.allSatisfy { !$0.isEmpty && !$0.contains("\t") })
        XCTAssertEqual(EFFWordList.words.first, "abacus")   // sanity: first EFF word
    }

    func test_passphrase_drawsAcrossFullList() {
        // Over many draws, the selected words should span a large fraction of the 7776-word list.
        var seen = Set<String>()
        for _ in 0..<2000 { seen.formUnion(PasswordGenerator.passphrase(.init(wordCount: 6)).split(separator: "-").map(String.init)) }
        XCTAssertGreaterThan(seen.count, 5000, "diceware not drawing across the full list (saw \(seen.count))")
    }

    func test_passphrase_options() {
        let p = PasswordGenerator.passphrase(.init(wordCount: 4, separator: ".", caps: .title))
        let words = p.split(separator: ".")
        XCTAssertEqual(words.count, 4)
        XCTAssertTrue(words.allSatisfy { $0.first!.isUppercase }, "title-case applied")
    }
}
